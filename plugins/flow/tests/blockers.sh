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
check() { # check <name> '<condition>': the condition is shell text, run whole; a FAIL shows its output
  if said="$( (eval "$2") 2>&1)"; then pass "$1"; else fail "$1"; [ -z "$said" ] || printf '%s\n' "$said" | sed 's/^/       /'; fi
}
jget() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
L="$P/adapters/local"
slug() { printf '%s' "$1" | tr ':/#' '---'; }
run_file() { printf '.flow/runs/%s.json' "$(slug "$1")"; }

# new_repo <dir> <pool_max>: a throwaway repo on the local adapter, the shell in it.
base=main
new_repo() {
  mkdir -p "$work/$1" && cd "$work/$1" && git init -q -b "$base" app && cd app || exit 1
  git config user.email t@t && git config user.name t
  printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
  printf 'adapters:\n  default: local\nbase: %s\npool:\npool_max: %s\nnotify:\n  desktop: false\n' "$base" "$2" > .flow/config.yaml
}
new_task() { "$P/scripts/new.sh" task "$1" --size S --body "## Acceptance
- [ ] done"; }
# block_on <item> <blocker...>: the owner's blocked_by edges, on the tracker, not in the flow state.
block_on() {
  blocked="$1"; shift
  edges="$(printf '"%s", ' "$@")"
  file=".flow/items/${blocked#local:}.md"
  sed "s|^blocked_by: .*|blocked_by: [${edges%, }]|" "$file" > "$file.new" && mv "$file.new" "$file"
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
check "ClaimedItemWithOpenBlocker_NamedRunExitsWithThePassOverCode: a claimed item at pr blocked by an open item exits 4, as a held item does" \
  '[ "$code" -eq 4 ]'
check "ClaimedItemWithOpenBlocker_NamedRunStartsNoRun: a claimed item at pr blocked by an open item writes no run, so no attempt can be counted" \
  '[ ! -f "$(run_file "$waiting")" ]'
"$P/scripts/board.sh" --json > "$work/board.json" 2>/dev/null
check "ClaimedBlockedItem_BoardJsonListsItsOpenBlockers: the board's model names the open item a claimed item waits on" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); i=[i for i in d[\"items\"] if i[\"id\"]==sys.argv[2]]; assert i and i[0][\"open_blockers\"]==[sys.argv[3]]" "$work/board.json" "$waiting" "$blocker"'
waiting_wt="$(basename "$("$P/scripts/steward.sh" find "$waiting")")"
"$P/scripts/board.sh" 2>/dev/null | awk -v row="| $waiting |" 'index($0, row) == 1' > "$work/board.row"
check "ClaimedBlockedItem_BoardRowShowsItsWorktree: the board's row for a claimed item blocked by an open item names the worktree it holds" \
  'grep -qF "$waiting_wt" "$work/board.row"'
check "ClaimedBlockedItem_BoardRowShowsItsBlocker: the board's row for a claimed item blocked by an open item names that item" \
  'grep -qF "$blocker" "$work/board.row"'
"$L/write-state.sh" "$blocker" gate=ambiguity >/dev/null
"$P/scripts/next.sh" >/dev/null 2>"$work/pick.err"
check "PickWhileTheBlockerWaitsAtAGate_SaysTheClaimedItemIsHeldBehindIt: a pick passes the claimed item over and names its blocker" \
  'grep -qF "$waiting behind $blocker (blocked by)" "$work/pick.err"'
check "PickWhileTheBlockerWaitsAtAGate_StartsNoRunForTheClaimedItem: a pick starts no run for a claimed item whose blocker is open" \
  '[ ! -f "$(run_file "$waiting")" ]'
"$L/write-state.sh" "$blocker" gate=none >/dev/null
"$L/close.sh" "$blocker" --comment fixed >/dev/null
"$P/scripts/next.sh" "$waiting" >/dev/null 2>&1
check "LastBlockerClosed_ItemStartsAtItsOwnStep: once its blocker closes, next.sh starts a run for the claimed item at pr again" \
  '[ "$(jget step < "$(run_file "$waiting")")" = pr ]'
# the resumed brief's wait section, from its heading to the next one
awk '/^## The wait is over/ { on = 1; next } /^## / { on = 0 } on' "$(jget reports < "$(run_file "$waiting")")/brief-pr.md" > "$work/wait.section"
check "LastBlockerClosed_BriefNamesTheClosedBlocker: the resumed step's wait section names the blocker it waited on" \
  'grep -qF "$blocker" "$work/wait.section"'
check "LastBlockerClosed_BriefMergesTheBaseFirst: the resumed step's wait section has the agent merge the item's base in" \
  'grep -qF "merge \`$base\`" "$work/wait.section"'
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
  check "ClaimedItemBlockedAt${at}_NamedRunExitsWithThePassOverCode: a blocker added at $at makes the named run exit 4" \
    '[ "$code" -eq 4 ]'
  check "ClaimedItemBlockedAt${at}_NamedRunStartsNoRun: a blocker added at $at stops the step before any run is written" \
    '[ ! -f "$(run_file "$held")" ]'
  check "ClaimedItemBlockedAt${at}_SaysItIsHeldBehindItsBlocker: the named run says which open item holds it" \
    'grep -qF "held behind $fix (blocked by)" "$work/held.$at.err"'
done
second="$(new_task "Second fix")"
first="$(new_task "First fix")"
both="$(claimed_at "Docs behind two fixes" pr "$first" "$second")"
"$L/close.sh" "$first" --comment fixed >/dev/null
"$P/scripts/next.sh" "$both" >/dev/null 2>"$work/both.err"
check "OneOfTwoBlockersClosed_StartsNoRun: an item resumes only when its last blocker closes, so one open blocker still holds it" \
  '[ ! -f "$(run_file "$both")" ]'
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
    '[ "$(grep -cF "$edge is held behind $second (blocked by)" "$work/job.$at.out")" -eq 3 ]'
  check "NextJobOnItemBlockedAt${at}OneFailureShortOfEscalation_RaisesNoGate: an open blocker at $at is never a failure, so the job raises no escalation" \
    '[ "$("$L/read.sh" "$edge" | jget state.gate)" = none ]'
  check "NextJobOnItemBlockedAt${at}OneFailureShortOfEscalation_KeepsItsAttemptCount: three job runs at $at behind an open blocker count no attempt" \
    '[ "$("$L/read.sh" "$edge" | jget state.attempts)" = "$((max - 1))" ]'
done

[ "$fails" -eq 0 ] && { echo "blockers: ok"; exit 0; }
echo "blockers: $fails failed"; exit 1
