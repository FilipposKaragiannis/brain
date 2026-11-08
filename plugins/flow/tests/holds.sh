#!/bin/sh
# holds.sh: the plan step's holds and the merge of the base before verify, on the local adapter
# in a throwaway repo with an eight-worktree pool. hold.sh candidates lists only claimed open
# items whose changes (or touches) overlap; the plan brief carries an Other open work section
# only with candidates; advance.sh writes changes, and a hold with its events.log line; next.sh
# lifts a hold once its holder closes and puts the release note in the brief; a verify run starts
# on a branch with the base merged in, or as the sync step when the merge conflicts.
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
st() { "$L/read.sh" "$1" | jget "state.$2"; }
slug() { printf '%s' "$1" | tr ':/#' '---'; }

cd "$work" || exit 1
git init -q -b main repo && cd repo || exit 1
git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf 'base\n' > conflict.txt && git add README.md conflict.txt && git commit -qm init
printf 'adapters:\n  default: local\nbase: main\npool:\n' > "$work/config.yaml"
for n in 1 2 3 4 5 6 7 8; do git worktree add -q --detach "../wt-$n"; printf '  - ../wt-%s\n' "$n" >> "$work/config.yaml"; done
mkdir -p .flow && cat "$work/config.yaml" > .flow/config.yaml && printf 'notify:\n  desktop: false\n' >> .flow/config.yaml
events=".flow/events.log"

echo "holds: candidates"
a="$("$L/create.sh" task "Parser rewrite" --size M --body x)"
b="$("$L/create.sh" task "Guide pages" --size M --body x)"
e="$("$L/create.sh" task "Zeta module" --size M --body x)"
g="$("$L/create.sh" task "Closed parser work" --size M --body x)"
d="$("$L/create.sh" task "Unclaimed parser work" --size M --body x)"
c="$("$L/create.sh" task "Parser errors" --size M --body x)"
f="$("$L/create.sh" task "Other corner" --size M --body x)"
wa="$("$P/scripts/steward.sh" claim "$a")"; "$P/scripts/steward.sh" claim "$b" >/dev/null
"$P/scripts/steward.sh" claim "$e" >/dev/null; "$P/scripts/steward.sh" claim "$g" >/dev/null
"$L/write-state.sh" "$a" step=implement 'touches=src/parse/**,docs/**' 'changes=src/parse/**'
"$L/write-state.sh" "$b" step=implement 'touches=docs/guide/**'
"$L/write-state.sh" "$e" step=implement 'touches=src/parse/x.py,src/z/**' 'changes=src/z/**'
"$L/write-state.sh" "$g" step=implement 'changes=src/parse/**'; "$L/close.sh" "$g"
"$L/write-state.sh" "$d" 'changes=src/parse/**'
"$L/write-state.sh" "$c" step=plan profile=task-M 'touches=src/parse/**,docs/**'
"$L/write-state.sh" "$f" step=plan profile=task-M 'touches=src/other/**'
mkdir -p "$wa/.flow/reports/$(slug "$a")" && printf '# plan\n' > "$wa/.flow/reports/$(slug "$a")/plan.md"
"$P/scripts/hold.sh" candidates "$c" > "$work/cand" 2>&1
check "candidates: a claimed open item whose changes overlap is listed with its changes and its plan report" \
  "grep -q '^- $a \"Parser rewrite\" (step implement): changes \`src/parse/\*\*\`; plan: \`$wa/.flow/reports/$(slug "$a")/plan.md\`' '$work/cand'"
check "candidates: a claimed item with no changes is judged by its touches, and says so" "grep -q '^- $b .*touches (no changes recorded) \`docs/guide/\*\*\`; no plan report' '$work/cand'"
check "candidates: changes, when recorded, are what counts, not the wider touches" "! grep -q '$e' '$work/cand'"
check "candidates: an unclaimed item and a closed one are not listed" "! grep -q '$d' '$work/cand' && ! grep -q '$g' '$work/cand' && [ \$(wc -l < '$work/cand') -eq 2 ]"
check "candidates --touches: the globs given replace the item's own" "[ \"\$('$P/scripts/hold.sh' candidates '$c' --touches 'src/z/y.py' --json | jget 0.id)\" = '$e' ] && [ \"\$('$P/scripts/hold.sh' candidates '$c' --touches 'src/z/y.py' --json | jget 1 2>/dev/null)\" = '' ]"
check "candidates: an item with no touches has none, and prints nothing" "[ -z \"\$('$P/scripts/hold.sh' candidates '$d')\" ]"
"$L/write-state.sh" "$b" "held_by=$c"
check "candidates: an item already held behind this one is left out, so two never wait on each other" "! '$P/scripts/hold.sh' candidates '$c' | grep -q '$b'"
"$L/write-state.sh" "$b" held_by=

echo "holds: the plan brief"
out="$("$P/scripts/next.sh" "$c" --json)"; rc="$(printf '%s' "$out" | jget reports)"
check "brief: a plan step with candidates gets the Other open work section with each item and the rule's path" \
  "grep -q '^## Other open work' '$rc/brief-plan.md' && grep -q '^- $a ' '$rc/brief-plan.md' && grep -q 'skills/plan/holds.md' '$rc/brief-plan.md' && [ -f '$P/skills/plan/holds.md' ]"
check "brief: the plan step's result names changes and hold" "grep -q '\"changes\"' '$rc/brief-plan.md' && grep -q '\"hold\"' '$rc/brief-plan.md'"
outf="$("$P/scripts/next.sh" "$f" --json)"; rf="$(printf '%s' "$outf" | jget reports)"
check "brief: a plan step with no candidates has no Other open work section" "[ -f '$rf/brief-plan.md' ] && ! grep -q 'Other open work' '$rf/brief-plan.md'"

echo "holds: advance"
printf '{"status":"done","summary":"planned","touches":["src/parse/**"],"changes":["src/parse/errors.py"],"hold":{"behind":"%s","reason":"both rewrite the token loop"}}\n' "$a" > "$rc/plan.json"
"$P/scripts/advance.sh" "$c" >/dev/null 2>&1; code=$?
check "advance: a plan with a hold writes held_by, held_reason and changes, and raises its gate as before" \
  "[ $code -eq 4 ] && [ \"\$(st '$c' held_by)\" = '$a' ] && [ \"\$(st '$c' held_reason)\" = 'both rewrite the token loop' ] && [ \"\$(st '$c' changes)\" = '[\"src/parse/errors.py\"]' ] && [ \"\$(st '$c' gate)\" = plan-approval ]"
check "advance: the hold is one held line in events.log" "grep -q \"	$c	held	behind $a: both rewrite the token loop\$\" '$events'"
check "advance: the gate tells the owner about the hold" "grep -q 'Held behind $a' .flow/gates/$(slug "$c").json"
"$P/scripts/hold.sh" set "$f" "$b" "an earlier plan" >/dev/null
printf '{"status":"done","summary":"planned","touches":["src/other/**"],"changes":["src/other/a.py"]}\n' > "$rf/plan.json"
"$P/scripts/advance.sh" "$f" >/dev/null 2>&1
check "advance: a plan with no hold writes changes only, and lifts a hold an earlier plan set" \
  "[ \"\$(st '$f' changes)\" = '[\"src/other/a.py\"]' ] && [ -z \"\$(st '$f' held_by)\" ] && [ -z \"\$(st '$f' held_reason)\" ] && grep -q \"	$f	unheld	replanned with no hold on $b\" '$events'"
"$P/scripts/hold.sh" set "$f" "$g" "closed" 2>/dev/null; code1=$?
"$P/scripts/hold.sh" set "$f" "$f" "itself" 2>/dev/null; code2=$?
check "hold set: a closed holder or the item itself is refused, nothing written" "[ $code1 -eq 1 ] && [ $code2 -eq 1 ] && [ -z \"\$(st '$f' held_by)\" ] && ! grep -q \"	$f	held	behind $g\" '$events'"

echo "holds: a held plan sent back"
"$P/scripts/gate.sh" clear "$c" --back "plan around the token loop" >/dev/null 2>&1
check "send back: the ready filter lets a held item at its plan step through" \
  "\"\$L/list-ready.sh\" | grep -q '\"$c\"'"
"$P/scripts/next.sh" "$c" >/dev/null 2>&1; code=$?
check "send back: the plan runs again while the holder is open, and its brief says the plan decides the hold" \
  "[ $code -eq 0 ] && [ \"\$(st '$c' held_by)\" = '$a' ] && grep -q '^## The hold now' '$rc/brief-plan.md' && grep -q 'held this item behind $a: both rewrite the token loop' '$rc/brief-plan.md'"
printf '{"status":"done","summary":"planned","touches":["src/parse/**"],"changes":["src/parse/errors.py"],"hold":{"behind":"%s","reason":"both rewrite the token loop"}}\n' "$a" > "$rc/plan.json"
"$P/scripts/advance.sh" "$c" >/dev/null 2>&1
check "send back: past the plan the hold keeps the item back again" \
  "[ \"\$(st '$c' gate)\" = plan-approval ] && ! \"\$L/list-ready.sh\" | grep -q '\"$c\"'"

echo "holds: release"
"$P/scripts/gate.sh" clear "$c" approved >/dev/null 2>&1
"$P/scripts/next.sh" "$c" >/dev/null 2>&1
rc="$(dirname "$rc")/$(slug "$c")"
check "release: while the holder is open the hold stays and the brief says nothing of it" "[ \"\$(st '$c' held_by)\" = '$a' ] && ! grep -q 'hold is over' '$rc/brief-implement.md'"
rm -f ".flow/runs/$(slug "$c").json"
"$L/close.sh" "$a"
check "board: a holder the open-item list leaves out is read once and named with its status" \
  "[ \"\$('$P/scripts/board.sh' --json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[\"holders\"]))')\" = '[{\"id\": \"$a\", \"status\": \"closed\"}]' ]"
"$P/scripts/next.sh" "$c" >/dev/null 2>&1
check "release: once the holder closed the brief says merge the base first and check the plan" \
  "grep -q '^## The hold is over' '$rc/brief-implement.md' && grep -q 'You were held behind $a, which has closed. First merge \`main\` into the branch' '$rc/brief-implement.md' && grep -q 'never rebase' '$rc/brief-implement.md' && grep -q 'gate ambiguity' '$rc/brief-implement.md'"
check "release: the hold is cleared and an unheld line written" "[ -z \"\$(st '$c' held_by)\" ] && [ -z \"\$(st '$c' held_reason)\" ] && grep -q \"	$c	unheld	$a closed\$\" '$events'"
rm -f ".flow/runs/$(slug "$c").json"

echo "verify: the base merged in first"
for x in "$b" "$e" "$c" "$f"; do "$P/scripts/steward.sh" release "$x" --force >/dev/null 2>&1; done
v="$("$L/create.sh" task "Verify behind" --size S --body x)"; w="$("$L/create.sh" task "Verify conflicted" --size S --body x)"
wv="$("$P/scripts/steward.sh" claim "$v")"; ww="$("$P/scripts/steward.sh" claim "$w")"
"$L/write-state.sh" "$v" step=verify profile=task-S; "$L/write-state.sh" "$w" step=verify profile=task-S
printf 'v\n' > "$wv/v.txt" && git -C "$wv" add v.txt && git -C "$wv" commit -qm v
printf 'mine\n' > "$ww/conflict.txt" && git -C "$ww" commit -qam w
printf 'theirs\n' > conflict.txt && printf 'm\n' > m.txt && git add conflict.txt m.txt && git commit -qm main-moves
wpre="$(git -C "$ww" rev-parse HEAD)"
outv="$("$P/scripts/next.sh" "$v" --json)"
check "verify: a clean branch behind its base gets the base merged in before the step, and an events.log line" \
  "[ \"\$(printf '%s' '$outv' | jget step)\" = verify ] && git -C '$wv' merge-base --is-ancestor main HEAD && [ -f '$wv/v.txt' ] && grep -q \"	$v	sync	merged main into flow/$(slug "$v") (1 commits behind) before verify\" '$events'"
outw="$("$P/scripts/next.sh" "$w" --json)"
rw="$(printf '%s' "$outw" | jget reports)"
check "verify: a base merge that conflicts is aborted and the run is the sync step, verify after it" \
  "[ \"\$(printf '%s' '$outw' | jget step)\" = sync ] && [ \"\$(cat '$rw/sync.md')\" = main ] && [ \"\$(git -C '$ww' rev-parse HEAD)\" = '$wpre' ] && [ -z \"\$(git -C '$ww' status --porcelain -- . ':!.flow')\" ] && grep -q 'Your own step is verify' '$rw/brief-sync.md' && [ \"\$(st '$w' step)\" = verify ]"
rm -f ".flow/runs/$(slug "$v").json"
"$P/scripts/next.sh" "$v" >/dev/null 2>&1
check "verify: a branch already in step with its base is left as it is" "[ \$(grep -c \"	$v	sync	\" '$events') -eq 1 ]"

[ "$fails" -eq 0 ] && { echo "holds: ok"; exit 0; }
echo "holds: $fails failed"; exit 1
