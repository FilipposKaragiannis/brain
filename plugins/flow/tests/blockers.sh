#!/bin/sh
# blockers.sh: a claimed item waits while a native blocker is open, on the local adapter in
# throwaway repos. next.sh passes the item over with no run, named or in a pick, at any step; the
# board lists it with its worktree and its open blockers; once the last blocker closes, the item
# starts at its own step with a brief that names the blocker and the base to merge; the next job
# run behind an open blocker counts no attempt and raises no gate.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unset FLOW_SLACK_WEBHOOK FLOW_HOME
mkdir -p "$work/home" "$work/offline" && HOME="$work/home" && export HOME && unset CODEX_HOME
for tool in curl wget gh osascript notify-send claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> '<condition>': the condition is shell text, run whole
  if (eval "$2") >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}
jget() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
L="$P/adapters/local"
slug() { printf '%s' "$1" | tr ':/#' '---'; }
run_file() { printf '.flow/runs/%s.json' "$(slug "$1")"; }

# new_repo <dir> <pool_max>: a throwaway repo on the local adapter, the shell in it.
new_repo() {
  mkdir -p "$work/$1" && cd "$work/$1" && git init -q -b main app && cd app || exit 1
  git config user.email t@t && git config user.name t
  printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
  printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: %s\nnotify:\n  desktop: false\n' "$2" > .flow/config.yaml
}
new_task() { "$P/scripts/new.sh" task "$1" --size S --body "## Acceptance
- [ ] done"; }
# block_on <item> <blocker...>: the owner's blocked_by edges, on the tracker, not in the flow state.
block_on() {
  blocked="$1"; shift
  edges="$(printf '"%s", ' "$@")"
  sed -i.bak "s|^blocked_by: .*|blocked_by: [${edges%, }]|" ".flow/items/${blocked#local:}.md"
}
# claimed_at <title> <step> <blocker...>: a claimed item at <step>, blocked after its claim.
claimed_at() {
  title="$1"; at="$2"; shift 2
  claimed="$(new_task "$title")"
  "$P/scripts/steward.sh" claim "$claimed" >/dev/null 2>&1
  "$L/write-state.sh" "$claimed" "step=$at" profile=task-S >/dev/null
  block_on "$claimed" "$@"
  echo "$claimed"
}

echo "blockers: a claimed item waits while a native blocker is open"
new_repo waits 3
blocker="$(new_task "Bot test fix")"
waiting="$(claimed_at "Docs that wait on the fix" pr "$blocker")"
"$P/scripts/next.sh" "$waiting" >/dev/null 2>&1; code=$?
check "ClaimedItemWithOpenBlocker_NamedRunIsPassedOverWithNoRun: a claimed item at pr blocked by an open item exits 4 and starts no run, so no attempt can be counted" \
  '[ "$code" -eq 4 ] && [ ! -f "$(run_file "$waiting")" ]'
"$P/scripts/board.sh" --json > "$work/board.json" 2>/dev/null
check "ClaimedBlockedItem_BoardJsonListsItsOpenBlockers: the board's model names the open item a claimed item waits on" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); i=[i for i in d[\"items\"] if i[\"id\"]==sys.argv[2]]; assert i and i[0][\"open_blockers\"]==[sys.argv[3]]" "$work/board.json" "$waiting" "$blocker"'
waiting_wt="$(basename "$("$P/scripts/steward.sh" find "$waiting")")"
"$P/scripts/board.sh" 2>/dev/null | awk -v row="| $waiting |" 'index($0, row) == 1' > "$work/board.row"
check "ClaimedBlockedItem_BoardRowShowsItsWorktreeAndBlocker: the board's row for a claimed item blocked by an open item names its worktree and the blocker" \
  '[ -s "$work/board.row" ] && grep -qF "$waiting_wt" "$work/board.row" && grep -qF "$blocker" "$work/board.row"'
"$L/write-state.sh" "$blocker" gate=ambiguity >/dev/null
"$P/scripts/next.sh" >/dev/null 2>"$work/pick.err"; code=$?
check "PickWithClaimedBlockedItem_SaysItIsHeldBehindItsBlocker: a pick with nothing ready names the claimed item as held behind its blocker" \
  '[ "$code" -eq 5 ] && grep -qF "$waiting behind $blocker (blocked by)" "$work/pick.err"'
check "PickWithClaimedBlockedItem_StartsNoRunForIt: a pick starts no run for a claimed item whose blocker is open" \
  '[ ! -f "$(run_file "$waiting")" ]'
"$L/write-state.sh" "$blocker" gate=none >/dev/null
"$L/close.sh" "$blocker" --comment fixed >/dev/null
"$P/scripts/next.sh" "$waiting" >/dev/null 2>&1; code=$?
check "LastBlockerClosed_ItemStartsAtItsOwnStep: once its blocker closes, next.sh starts the claimed item at pr again" \
  '[ "$code" -eq 0 ] && [ "$(jget step < "$(run_file "$waiting")")" = pr ]'
check "LastBlockerClosed_BriefNamesTheBlockerAndTheBaseToMerge: the resumed step's brief names the closed blocker beside the base it merges first" \
  'grep -F "$blocker" "$(jget reports < "$(run_file "$waiting")")/brief-pr.md" | grep -qF "main"'
"$P/scripts/board.sh" 2>/dev/null | awk -v row="| $waiting |" 'index($0, row) == 1' > "$work/board.closed.row"
check "LastBlockerClosed_BoardRowShowsNoBlocker: a blocker the lists leave out because it closed reads as closed, so the row shows none" \
  'grep -q " | - |\$" "$work/board.closed.row"'
unreadable="local:task/404"
behind_unreadable="$(claimed_at "Docs behind a missing item" pr "$unreadable")"
"$P/scripts/board.sh" 2>/dev/null | awk -v row="| $behind_unreadable |" 'index($0, row) == 1' > "$work/board.unreadable.row"
check "ClaimedItemBlockedByAnUnreadableItem_BoardRowNamesTheBlocker: a blocker no tracker reads as closed holds the item in next.sh, so the board names it too" \
  'grep -qF "$unreadable" "$work/board.unreadable.row"'

echo "blockers: a blocker added at pr or verify holds a claimed item, with no attempt and no escalation"
new_repo steps 5
fix="$(new_task "Bot test fix")"
for at in pr verify; do
  held="$(claimed_at "Docs at $at" "$at" "$fix")"
  "$P/scripts/next.sh" "$held" >/dev/null 2>"$work/held.$at.err"; code=$?
  check "ClaimedItemBlockedAt${at}_NamedRunIsPassedOverWithNoRun: a blocker added at $at exits 4 and starts no run" \
    '[ "$code" -eq 4 ] && [ ! -f "$(run_file "$held")" ]'
  check "ClaimedItemBlockedAt${at}_SaysItIsHeldBehindItsBlocker: the named run says which open item holds it" \
    'grep -qF "held behind $fix (blocked by)" "$work/held.$at.err"'
done
second="$(new_task "Second fix")"
first="$(new_task "First fix")"
both="$(claimed_at "Docs behind two fixes" pr "$first" "$second")"
"$L/close.sh" "$first" --comment fixed >/dev/null
"$P/scripts/next.sh" "$both" >/dev/null 2>"$work/both.err"; code=$?
check "OneOfTwoBlockersClosed_ItemStaysHeld: an item resumes only when its last blocker closes, so one open blocker still holds it" \
  '[ "$code" -eq 4 ] && [ ! -f "$(run_file "$both")" ]'
check "OneOfTwoBlockersClosed_HeldBehindTheOpenOne: the pass-over names the blocker still open" \
  'grep -qF "held behind $second (blocked by)" "$work/both.err"'
mkdir -p "$work/refusing-bin"
cat > "$work/refusing-bin/claude" <<'HOST'
#!/bin/sh
brief="$(printf '%s' "$*" | sed -n 's/.*Follow the brief in \([^ ]*\) .*/\1/p')"
report="$(sed -n 's/^Write `\(.*\)`:$/\1/p' "$brief" 2>/dev/null | head -1)"
[ -z "$report" ] || { mkdir -p "$(dirname "$report")" && printf '{"status":"fail","summary":"Nothing done. The blocker is still open."}\n' > "$report"; }
echo '{"type":"result","subtype":"success","is_error":false,"result":"Nothing done. The blocker is still open."}'
HOST
chmod +x "$work/refusing-bin/claude"
max="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['max_attempts'])" "$P/profiles.json")"
for at in pr verify; do
  edge="$(claimed_at "Docs at $at one failure short" "$at" "$second")"
  "$L/write-state.sh" "$edge" "attempts=$((max - 1))" >/dev/null
  for run in 1 2 3; do PATH="$work/refusing-bin:$PATH" "$P/jobs/next.sh" claude "$edge" >> "$work/job.$at.out" 2>&1; done
  check "NextJobOnItemBlockedAt${at}_EachRunSaysItIsHeldBehindItsBlocker: each of three job runs at $at reaches the pass-over and says so" \
    '[ "$(grep -cF "quiet: $edge is held behind $second (blocked by)" "$work/job.$at.out")" -eq 3 ]'
  check "NextJobOnItemBlockedAt${at}OneFailureShortOfEscalation_RaisesNoGate: an open blocker at $at is never a failure, so the job raises no escalation" \
    '[ "$("$L/read.sh" "$edge" | jget state.gate)" = none ]'
  check "NextJobOnItemBlockedAt${at}OneFailureShortOfEscalation_KeepsItsAttemptCount: three job runs at $at behind an open blocker count no attempt" \
    '[ "$("$L/read.sh" "$edge" | jget state.attempts)" = "$((max - 1))" ]'
done

[ "$fails" -eq 0 ] && { echo "blockers: ok"; exit 0; }
echo "blockers: $fails failed"; exit 1
