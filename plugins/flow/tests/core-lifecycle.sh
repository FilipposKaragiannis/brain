#!/bin/sh
# core-lifecycle.sh: the config reader, the local adapter, the steward, next and advance, re-sizing and
# gates, and overlap.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
echo "config"
check "yaml scalar"       [ "$(yaml_get .flow/config.yaml base)" = "main" ]
check "yaml nested"       [ "$(yaml_get .flow/config.yaml adapters.default)" = "local" ]
check "yaml list"         [ "$(yaml_get .flow/config.yaml pool | wc -l | tr -d ' ')" = "2" ]
check "yaml missing"      [ -z "$(yaml_get .flow/config.yaml nothing.here)" ]
check_all "slug"              '[ "$(item_slug '\''gh#12'\'')" = "gh-12" ] && [ "$(item_slug local:bug/3)" = "local-bug-3" ]'
check_all "profile select"    '[ "$(profile_select task S)" = "task-S" ] && [ "$(profile_select bug M)" = "bugfix" ] && [ "$(profile_select task XL)" = "task-L" ]'

echo "local adapter"
t1="$("$P/adapters/local/create.sh" task "First task" --size S --body "Do it.")"
b1="$("$P/adapters/local/create.sh" bug "A bug" --blocked-by "$t1")"
t2="$("$P/adapters/local/create.sh" task "Medium task")"
check_all "create ids"        '[ "$t1" = "local:task/1" ] && [ "$b1" = "local:bug/1" ] && [ "$t2" = "local:task/2" ]'
check "read title"        [ "$("$P/adapters/local/read.sh" "$t1" | jget title)" = "First task" ]
check "read default size" [ "$("$P/adapters/local/read.sh" "$t2" | jget size)" = "" ]
"$P/adapters/local/write-state.sh" "$t1" step=implement attempts=2 touches=src/a/**,docs/*
check_all "write-state"       '[ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "implement" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.touches)" = '\''["src/a/**", "docs/*"]'\'' ]'
"$P/adapters/local/write-state.sh" "$t1" step= attempts=0 touches=
printf 'hello: world\n' | "$P/adapters/local/comment.sh" "$t1"
check "comment appended"  grep -q 'hello: world' .flow/items/task/1.md
chmod 600 .flow/items/task/1.md
"$P/adapters/local/write-state.sh" "$t1" step=
check "PrivateItemWrittenAgain_StaysPrivate: an item made 0600 is still 0600 after a state write, because the whole-file replace keeps the old file's mode" \
  [ "$(python3 -I -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' .flow/items/task/1.md)" = "0o600" ]
chmod 644 .flow/items/task/1.md
check "TemporaryItemFile_IsOwnerOnlyFromCreation: the temporary file a whole-item write fills is 0600 under umask 022 before any content is written, because a private item's contents never sit in a file others can read" \
  python3 -I -B -c 'import os, stat, sys; sys.path.insert(0, sys.argv[1]); import _item; os.umask(0o022)
with _item.create_owner_only(sys.argv[2]) as f: sys.exit(stat.S_IMODE(os.fstat(f.fileno()).st_mode) != 0o600)' "$P/adapters/local" "$work/owner-only.tmp"
check "list open"        [ "$("$P/adapters/local/list.sh" | jget 2.id)" = "local:task/2" ]
printf '[{"id":"local:task/90","status":"open","state":{"gate":"none"},"blocked_by":["gh#999999"],"open_blockers":[]},{"id":"local:task/91","status":"open","state":{"gate":"none"},"blocked_by":[],"open_blockers":["gh#1"]}]' | "$P/scripts/filter-ready.sh" > "$work/ready.out"
check "ready: an item that lists its open blockers is judged by that list, with no read per blocker" sh -c "grep -q 'local:task/90' '$work/ready.out' && ! grep -q 'local:task/91' '$work/ready.out'"
check "ready excludes blocked" [ "$("$P/adapters/local/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "local:task/1,local:task/2" ]
"$P/adapters/local/link-pr.sh" "$t2" https://example/pr/1
check "link-pr"           [ "$("$P/adapters/local/read.sh" "$t2" | jget state.pr)" = "https://example/pr/1" ]
env -u CODEX_THREAD_ID -u CODEX_SANDBOX CLAUDECODE=1 "$P/adapters/local/link-pr.sh" "$t2" https://example/pr/1
check "link-pr: a Claude session is recorded as the PR's host" [ "$("$P/adapters/local/read.sh" "$t2" | jget state.pr_host)" = "claude" ]
"$P/adapters/local/write-state.sh" "$t2" pr=

echo "steward"
w1="$("$P/scripts/steward.sh" claim "$t1")"
check "claim path"        [ "$w1" = "$(cd ../wt-1 && pwd -P)" ]
check "claim branch"      [ "$(git -C "$w1" symbolic-ref --short HEAD)" = "flow/local-task-1" ]
check "claim file"        [ "$(jget item < "$w1/.flow/claim.json")" = "$t1" ]
mirror_on "a claim is shared through the record, not the tracker" check "claim in tracker"  [ "$("$P/adapters/local/read.sh" "$t1" | jget state.worktree)" = "wt-1" ]
check "claim again same"  [ "$("$P/scripts/steward.sh" claim "$t1")" = "$w1" ]
check "find"              [ "$("$P/scripts/steward.sh" find "$t1")" = "$w1" ]
printf 'x\n' > "$w1/dirty.txt"
"$P/scripts/steward.sh" release "$t1" >/dev/null 2>&1; code=$?
check_all "release refuses dirty (exit 3)" '[ "$code" -eq 3 ] && [ -f "$w1/.flow/claim.json" ]'
rm "$w1/dirty.txt"
check "release clean"     "$P/scripts/steward.sh" release "$t1"
check_all "released: on its idle branch main-wt-1 at main, no claim, tracker cleared" '[ ! -f "$w1/.flow/claim.json" ] && [ "$(git -C "$w1" symbolic-ref --short HEAD)" = main-wt-1 ] && [ "$(git -C "$w1" rev-parse HEAD)" = "$(git rev-parse main)" ] && [ -z "$("$P/adapters/local/read.sh" "$t1" | jget state.worktree)" ]'
check "pool table: a free worktree shows its idle branch" sh -c "'$P/scripts/steward.sh' pool | grep -q 'wt-1 *main-wt-1 .*free'"
check "pool table"        sh -c "'$P/scripts/steward.sh' pool | grep -q 'wt-2.*free'"

echo "next and advance"
out="$("$P/scripts/next.sh" --json)"; code=$?
check_all "next picks first ready" '[ "$code" -eq 0 ] && [ "$(printf '\''%s'\'' "$out" | jget item)" = "$t1" ] && [ "$(printf '\''%s'\'' "$out" | jget step)" = "implement" ]'
brief="$(printf '%s' "$out" | jget brief)"; reports="$(printf '%s' "$out" | jget reports)"
check_all "brief written in the worktree" '[ -f "$brief" ] && grep -q '\''cd "'\'' "$brief" && grep -q '\''implement.json'\'' "$brief"'
check "run recorded"      [ "$(running "$t1")" = yes ]
check_all "state step"        '[ "$(record get "$t1" step)" = "implement" ] && [ "$(record get "$t1" profile)" = "task-S" ]'
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "second next on a running item: exit 7" [ "$code" -eq 7 ]
out2="$("$P/scripts/next.sh" --json)"
check_all "next picks the other item in wt-2" '[ "$(printf '\''%s'\'' "$out2" | jget item)" = "$t2" ] && [ "$(printf '\''%s'\'' "$out2" | jget step)" = "design" ] && [ "$(basename "$(printf '\''%s'\'' "$out2" | jget worktree)")" = "wt-2" ]'
"$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "nothing ready: exit 5" [ "$code" -eq 5 ]
"$P/scripts/advance.sh" "$t1" >/dev/null 2>&1; code=$?
check "advance without a result: exit 2" [ "$code" -eq 2 ]
printf '{"status":"done","summary":"built","touches":["src/a/**"]}\n' > "$reports/implement.json"
check "advance done -> test" sh -c "'$P/scripts/advance.sh' '$t1' --json | grep -q '\"next_step\":\"test\"'"
check "advance done: the claim follows the issue to test" [ "$(claim_step "$t1")" = test ]
check "touches stored"    [ "$(record get "$t1" touches)" = '["src/a/**"]' ]
check "run cleared"       [ "$(running "$t1")" = no ]
"$P/scripts/next.sh" "$t1" >/dev/null
"$P/scripts/advance.sh" "$t1" --status fail --summary "red" >/dev/null; "$P/scripts/next.sh" "$t1" >/dev/null
check_all "fail: attempt 1, step test stays" '[ "$(record get "$t1" attempts)" = "1" ] && [ "$(record get "$t1" step)" = "test" ]'
"$P/scripts/advance.sh" "$t1" --status fail --summary "red again" >/dev/null; "$P/scripts/next.sh" "$t1" >/dev/null
"$P/scripts/advance.sh" "$t1" --status fail --summary "still red" >/dev/null 2>&1; code=$?
check_all "third fail: escalation gate (exit 4)" '[ "$code" -eq 4 ] && [ "$(record get "$t1" gate)" = "escalation" ] && [ -n "$(record list gates "$t1")" ]'
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "next at a gate: exit 4" [ "$code" -eq 4 ]
check "gate list"         sh -c "'$P/scripts/gate.sh' list | grep -q escalation"
"$P/scripts/gate.sh" clear "$t1" "fixed" >/dev/null
check_all "gate cleared"      '[ "$(record get "$t1" gate)" = "none" ] && [ -z "$(record list gates "$t1")" ] && [ "$(record get "$t1" attempts)" = "0" ]'
for s in test review; do "$P/scripts/next.sh" "$t1" >/dev/null; printf '{"status":"done"}\n' > "$reports/$s.json"; "$P/scripts/advance.sh" "$t1" >/dev/null; done
"$P/scripts/next.sh" "$t1" >/dev/null
printf '{"status":"fail","attempts":1,"checks":[{"name":"tests","status":"fail","summary":"1 failed"}]}\n' > "$reports/verify.json"
check "verify fail -> back to implement" sh -c "'$P/scripts/advance.sh' '$t1' --json | grep -q '\"next_step\":\"implement\"'"
check "verify fail: the claim follows the issue back to implement" [ "$(claim_step "$t1")" = implement ]
"$P/scripts/next.sh" "$t1" >/dev/null; printf '{"status":"done"}\n' > "$reports/implement.json"; "$P/scripts/advance.sh" "$t1" >/dev/null
for s in test review; do "$P/scripts/next.sh" "$t1" >/dev/null; "$P/scripts/advance.sh" "$t1" >/dev/null; done
"$P/scripts/next.sh" "$t1" >/dev/null
printf '{"status":"pass","attempts":2,"checks":[{"name":"tests","status":"pass","summary":"ok"}]}\n' > "$reports/verify.json"
check "verify pass -> pr" sh -c "'$P/scripts/advance.sh' '$t1' --json | grep -q '\"next_step\":\"pr\"'"
"$P/scripts/next.sh" "$t1" >/dev/null; printf '{"status":"done","summary":"PR open","pr":"https://gh/pull/90"}\n' > "$reports/pr.json"
"$P/scripts/advance.sh" "$t1" >/dev/null 2>&1; code=$?
check_all "pr done -> merge gate (exit 4), step done" '[ "$code" -eq 4 ] && [ "$(record get "$t1" gate)" = "merge" ] && [ "$(record get "$t1" step)" = "done" ]'
check "pr done at the merge gate: the claim says done, as the issue does" [ "$(claim_step "$t1")" = done ]
"$P/scripts/gate.sh" clear "$t1" merged >/dev/null
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "next on a done item: exit 6" [ "$code" -eq 6 ]
record set "$t1" pr= pr_host= >/dev/null

echo "re-size and gates"
r2="$(printf '%s' "$out2" | jget reports)"
printf '{"status":"done","size":"L","summary":"bigger"}\n' > "$r2/design.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "M -> L stops at plan-approval" '[ "$code" -eq 4 ] && [ "$(record get "$t2" gate)" = "plan-approval" ] && [ "$(record get "$t2" size)" = "L" ]'
"$P/scripts/gate.sh" clear "$t2" "replanned" >/dev/null
"$P/scripts/next.sh" "$t2" >/dev/null; printf '{"status":"done"}\n' > "$r2/design.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1
check_all "L profile after re-size" '[ "$(record get "$t2" profile)" = "task-L" ] && [ "$(record get "$t2" step)" = "plan" ]'
"$P/scripts/next.sh" "$t2" >/dev/null; printf '{"status":"done","summary":"planned"}\n' > "$r2/plan.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "plan -> plan-approval gate, step implement" '[ "$code" -eq 4 ] && [ "$(record get "$t2" step)" = "implement" ]'
check "plan at the plan-approval gate: the claim says implement, as the issue does" [ "$(claim_step "$t2")" = implement ]
check_all "plan-approval message leads with the ask in bold" 'record get "$t2" gate.message | head -1 | grep -q "^\*\*Approve the plan"'
check "send back with no message: refused, exit 2" sh -c "'$P/scripts/gate.sh' clear '$t2' --back; [ \$? -eq 2 ]"
"$P/scripts/gate.sh" clear "$t2" --back "Add a rollback phase." >/dev/null
check_all "send back: the plan step runs again, gate none, the note kept" '[ "$(record get "$t2" step)" = "plan" ] && [ "$(record get "$t2" gate)" = "none" ] && [ "$(record get "$t2" answer)" = "Add a rollback phase." ] && [ -z "$(record list gates "$t2")" ]'
check "send back: the claim follows the issue back to plan" [ "$(claim_step "$t2")" = plan ]
check_all "send back: one answered line in events.log, the note on one line" 'tail -1 .flow/events.log | grep -q "	$t2	answered	plan-approval, sent back to plan: Add a rollback phase.\$"'
brief2="$("$P/scripts/next.sh" "$t2" 2>/dev/null | sed -n 's/^  brief: //p')"
check_all "send back: the plan brief carries the note" '[ -n "$brief2" ] && grep -q "Add a rollback phase." "$brief2"'
printf '{"status":"done","summary":"replanned"}\n' > "$r2/plan.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "replanned -> plan-approval again" '[ "$code" -eq 4 ] && [ "$(record get "$t2" gate)" = "plan-approval" ] && [ "$(record get "$t2" step)" = "implement" ]'
"$P/scripts/gate.sh" clear "$t2" approved >/dev/null
check_all "clear: one answered line in events.log with the gate and the answer" 'tail -1 .flow/events.log | grep -q "	$t2	answered	plan-approval: approved\$"'
"$P/scripts/next.sh" "$t2" >/dev/null
printf '{"status":"gate","gate":"ambiguity","message":"A or B?"}\n' > "$r2/implement.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "agent raises ambiguity" '[ "$code" -eq 4 ] && [ "$(record get "$t2" gate)" = "ambiguity" ] && record get "$t2" gate.message | grep -q '\''A or B'\'''
"$P/scripts/gate.sh" clear "$t2" "A" > "$work/answer.out"
check_all "clear at a step next runs: the answer waits on next, and the clear says to run it" '[ "$(record get "$t2" answer_pending)" = next ] && grep -q "run next $t2" "$work/answer.out"'
check "board: a cleared gate whose answer waits on a run shows it" sh -c "'$P/scripts/board.sh' | grep -q '| $t2 | .* | none, answer waits on next |'"
b2="$("$P/adapters/local/create.sh" bug "Small bug" --size S)"
"$P/scripts/steward.sh" release "$t1" >/dev/null
"$P/scripts/next.sh" "$b2" >/dev/null
rb="$(record get "$b2" run.reports)"
printf '{"status":"done","size":"M"}\n' > "$rb/reproduce.json"
check "S -> M continues" sh -c "'$P/scripts/advance.sh' '$b2' --json | grep -q '\"next_step\":\"implement\"'"
check "bugfix profile kept for a bug" [ "$(record get "$b2" profile)" = "bugfix" ]

echo "overlap"
record set "$t2" touches=src/a/**
t3="$("$P/adapters/local/create.sh" task "Overlapping" --size S)"
record set "$t3" touches=src/a/sub/**
"$P/scripts/next.sh" "$t2" >/dev/null
check "next takes the answer: a run starts with it in its brief, nothing waits" [ -z "$(record get "$t2" answer_pending)" ]
"$P/scripts/next.sh" "$t3" >/dev/null 2>&1; code=$?
check "overlapping claim refused? (explicit item runs; pool full)" [ "$code" -ne 0 ]
"$P/adapters/local/close.sh" "$b2" --comment done
"$P/scripts/steward.sh" release "$b2" --force >/dev/null 2>&1
out="$("$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "overlap holds no pick: the queue takes the item whose touches overlap a running one's, as the plan's hold (held_by) is what keeps them apart" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$t3"
"$P/scripts/next.sh" >/dev/null 2>"$work/nothing.err"; code=$?
check "nothing ready says why: the running, the blocked and the done items, counted" sh -c "[ $code -eq 5 ] && grep -qx 'nothing ready: 2 running, 1 blocked, 1 done (every step ran)' '$work/nothing.err'"
# Back as the sections below expect it: t3 neither running nor claimed.
end_run "$t3"; "$P/scripts/steward.sh" release "$t3" --force >/dev/null 2>&1
record set "$t3" step= profile= last_event=

[ "$fails" -eq 0 ] && { echo "core-lifecycle: ok"; exit 0; }
echo "core-lifecycle: $fails failed"; exit 1
