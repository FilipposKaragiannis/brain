#!/bin/sh
# gate-options.sh: the owner's own worktree as a reserve, a cleared gate no step owns, gate options,
# roles and conditions, and a step with no result file.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
echo "reserve: the owner's own worktree"
rroot="$work/reserve"; mkdir -p "$rroot"
git init -q -b main "$rroot/app" && cd "$rroot/app" || exit 1
git config user.email t@t && git config user.name "Grace Hopper"
printf 'hi\n' > README.md && git add -A && git commit -qm init
for n in 1 2; do git worktree add -q -b "main-wt-$n" "../wt-$n"; done
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\npool_max: 2\nnotify:\n  desktop: false\n' > .flow/config.yaml
rw1="$(cd ../wt-1 && pwd -P)"; rw2="$(cd ../wt-2 && pwd -P)"
rv="$("$P/scripts/steward.sh" reserve --name "Ada Lovelace")"
check "reserve: prints the path of a free pool worktree" [ "$rv" = "$rw1" ]
check "reserve: the claim records who reserved it" [ "$(jget reserved < "$rw1/.flow/claim.json")" = "Ada Lovelace" ]
check "reserve: the claim names no item" [ -z "$(jget item < "$rw1/.flow/claim.json")" ]
ra="$("$P/adapters/local/create.sh" task "Claimed beside a reservation" --size S --body "x")"
check "claim: a reserved worktree is passed over" [ "$("$P/scripts/steward.sh" claim "$ra")" = "$rw2" ]
rb="$("$P/adapters/local/create.sh" task "No room left" --size S --body "x")"
"$P/scripts/next.sh" "$rb" >/dev/null 2>&1; code=$?
check "next: with the only unclaimed worktree reserved there is no free worktree (exit 3)" [ "$code" -eq 3 ]
"$P/scripts/steward.sh" reserve --name "Ada Lovelace" >/dev/null 2>&1; code=$?
check "reserve: no free worktree at pool_max exits 3, as claim does" [ "$code" -eq 3 ]
check "pool: a reserved worktree shows who reserved it" sh -c "'$P/scripts/steward.sh' pool | grep -q '^wt-1 .*reserved by Ada Lovelace'"
check "board: the pool shows a reserved worktree as reserved by that name" sh -c "'$P/scripts/board.sh' | grep -q '^| wt-1 |.*| reserved by Ada Lovelace |'"
"$P/adapters/local/close.sh" "$ra" >/dev/null
"$P/scripts/steward.sh" sweep >/dev/null 2>&1
check "sweep: a reserved worktree keeps its reservation" [ "$(jget reserved < "$rw1/.flow/claim.json")" = "Ada Lovelace" ]
python3 -c '
import json, sys, time
p = sys.argv[1] + "/.flow/claim.json"
d = json.load(open(p)); d["claimed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800)); json.dump(d, open(p, "w"))' "$rw1"
reserved_head="$(git -C "$rw1" rev-parse HEAD)"
printf 'later\n' > later.txt && git add -A && git commit -qm later
"$P/scripts/steward.sh" health > "$rroot/health.out" 2>&1
check "health: a free worktree behind the base moves to its tip" [ "$(git -C "$rw2" rev-parse HEAD)" = "$(git rev-parse main)" ]
check "health: a reserved worktree is not moved to the base tip" [ "$(git -C "$rw1" rev-parse HEAD)" = "$reserved_head" ]
check "health: a reserved claim with no item, commits or run for two days is not released" [ -f "$rw1/.flow/claim.json" ]
"$P/scripts/steward.sh" release "$rw1" >/dev/null 2>&1
check "release: a reserved worktree is freed" [ ! -f "$rw1/.flow/claim.json" ]
"$P/scripts/steward.sh" reserve >/dev/null
check "reserve: with no --name the reservation is under git user.name" [ "$(jget reserved < "$rw1/.flow/claim.json")" = "Grace Hopper" ]
"$P/scripts/steward.sh" reserve --name >/dev/null 2>&1; code=$?
check "reserve: --name with no name is bad usage (exit 2)" [ "$code" -eq 2 ]
rv="$("$P/scripts/steward.sh" reserve wt-2 --name "Ada Lovelace")"
check_all "reserve by name: takes the named pool worktree under --name" '[ "$rv" = "$rw2" ] && [ "$(jget reserved < "$rw2/.flow/claim.json")" = "Ada Lovelace" ]'
"$P/scripts/steward.sh" release "$rw2" >/dev/null 2>&1
check "reserve by path: an absolute pool path takes that worktree" [ "$("$P/scripts/steward.sh" reserve "$rw2")" = "$rw2" ]
"$P/scripts/steward.sh" release "$rw2" >/dev/null 2>&1
check "reserve by path: a relative pool path takes that worktree" [ "$("$P/scripts/steward.sh" reserve ../wt-2)" = "$rw2" ]
"$P/scripts/steward.sh" release "$rw2" >/dev/null 2>&1
"$P/scripts/steward.sh" reserve wt-1 --name "Ada Lovelace" > "$rroot/reserve.out" 2>&1; code=$?
check_all "reserve by name: a reserved worktree exits 3 and names who holds it" '[ "$code" -eq 3 ] && grep -q "wt-1 is reserved by Grace Hopper" "$rroot/reserve.out" && [ "$(jget reserved < "$rw1/.flow/claim.json")" = "Grace Hopper" ]'
rd="$("$P/adapters/local/create.sh" task "Claimed before a reserve by name" --size S --body "x")"
"$P/scripts/steward.sh" claim "$rd" >/dev/null
"$P/scripts/steward.sh" reserve wt-2 > "$rroot/reserve.out" 2>&1; code=$?
check_all "reserve by name: a claimed worktree exits 3 and names the item" '[ "$code" -eq 3 ] && grep -q "wt-2 is claimed by $rd" "$rroot/reserve.out" && [ -z "$(jget reserved < "$rw2/.flow/claim.json")" ]'
"$P/scripts/steward.sh" release "$rd" >/dev/null 2>&1
printf 'draft\n' > "$rw2/draft.txt"
"$P/scripts/steward.sh" reserve wt-2 > "$rroot/reserve.out" 2>&1; code=$?
check_all "reserve by name: a dirty worktree exits 3, says so and is not reserved" '[ "$code" -eq 3 ] && grep -q "wt-2 has uncommitted changes" "$rroot/reserve.out" && [ ! -f "$rw2/.flow/claim.json" ]'
rm -f "$rw2/draft.txt"
"$P/scripts/steward.sh" reserve wt-9 > "$rroot/reserve.out" 2>&1; code=$?
check_all "reserve by name: a worktree outside the pool exits 3 and says so" '[ "$code" -eq 3 ] && grep -q "wt-9 is not a worktree in the pool" "$rroot/reserve.out"'
"$P/scripts/steward.sh" reserve wt-1 wt-2 >/dev/null 2>&1; code=$?
check_all "reserve by name: two worktrees is bad usage (exit 2) and reserves nothing" '[ "$code" -eq 2 ] && [ ! -f "$rw2/.flow/claim.json" ]'
rc="$("$P/adapters/local/create.sh" task "Claimed by the worktree hook" --size S --body "x")"
sleep 30 & held=$!
mkdir -p .flow/claim.lock && echo "$held" > .flow/claim.lock/pid
FLOW_LOCK_WAIT=1 "$P/scripts/steward.sh" claim "$rc" >/dev/null 2>&1; code=$?
check_all "claim: an allocation in flight makes a claim outside next wait, then exit 75 with nothing claimed" '[ "$code" -eq 75 ] && [ ! -f "$rw2/.flow/claim.json" ]'
FLOW_LOCK_WAIT=1 "$P/scripts/steward.sh" reserve --name "Ada Lovelace" >/dev/null 2>&1; code=$?
check_all "reserve: an allocation in flight makes it wait, then exit 75 with nothing reserved" '[ "$code" -eq 75 ] && [ ! -f "$rw2/.flow/claim.json" ]'
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null
check_all "claim: once the holder is gone it takes the free worktree and frees the claim lock" '[ "$("$P/scripts/steward.sh" claim "$rc")" = "$rw2" ] && [ ! -d .flow/claim.lock ]'

echo "a cleared gate whose answer no step owns (gh#157)"
# An item past its last step, with no PR: no step acts on the answer, so the clear fails out loud
# and the gate stays.
dn="$("$P/adapters/local/create.sh" task "Done, its PR merged by hand" --size S)"; "$P/adapters/local/write-state.sh" "$dn" step=done
"$P/scripts/gate.sh" raise "$dn" ambiguity "1. Merge main into epic/525 first?" >/dev/null 2>&1
"$P/scripts/gate.sh" clear "$dn" "Go with a, merge main into epic/525" > "$work/answer.out" 2>&1; code=$?
check_all "clear at done with no PR: refused out loud, the gate and its record stay" '[ "$code" = 1 ] && grep -q "no step acts on this answer" "$work/answer.out" && [ "$("$P/adapters/local/read.sh" "$dn" | jget state.gate)" = ambiguity ] && [ -f .flow/gates/$(item_slug "$dn").json ] && [ -z "$("$P/adapters/local/read.sh" "$dn" | jget state.answer)" ]'
"$P/scripts/gate.sh" clear "$dn" --back "Merge it again" > "$work/answer.out" 2>&1; code=$?
check_all "send back at done: refused, no step runs the done step again" '[ "$code" = 1 ] && grep -q "no step to send back to" "$work/answer.out" && [ "$("$P/adapters/local/read.sh" "$dn" | jget state.gate)" = ambiguity ]'
"$P/scripts/gate.sh" clear "$dn" > "$work/answer.out" 2>&1; code=$?
check_all "clear at done with no answer (done by hand): cleared, nothing waits" '[ "$code" = 0 ] && [ "$("$P/adapters/local/read.sh" "$dn" | jget state.gate)" = none ] && [ -z "$("$P/adapters/local/read.sh" "$dn" | jget state.answer_pending)" ] && ! grep -q "run next" "$work/answer.out"'
"$P/adapters/local/write-state.sh" "$dn" step=plan answer_pending=next answered_at=2026-01-01T00:00:00Z
check "board: an answer no run took past the gate reminder is named in Health" sh -c "'$P/scripts/board.sh' | grep -q '^- $dn: the answer to its gate has waited .* on next\$'"
"$P/adapters/local/close.sh" "$dn" >/dev/null

echo "gate options, roles and conditions"
# A gate the owner can act on: options as data, who asks and who answers, and a condition the
# health job watches. Its own repo with an origin, the local tracker and its own fake gh.
oroot="$work/gate-options"; mkdir -p "$oroot"
git init -q --bare "$oroot/origin.git" && git clone -q "$oroot/origin.git" "$oroot/app" 2>/dev/null
cd "$oroot/app" || exit 1
git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main
printf 'hi\n' > README.md && git add -A && git commit -qm init && git push -q -u origin main
for n in 1 2; do git worktree add -q -b "main-wt-$n" "../wt-$n"; done
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > .flow/config.yaml
export FAKE_GH_DIR="$work/gate-options-gh"; mkdir -p "$FAKE_GH_DIR"; cp "$P/tests/_fake_gh.py" "$FAKE_GH_DIR/"
printf '{"issues": [], "pr": {"number": 90, "state": "OPEN", "isDraft": false, "mergedAt": null, "url": "https://github.com/acme/widgets/pull/90", "headRefName": "flow/local-task-1", "baseRefName": "main", "mergeable": "MERGEABLE", "updatedAt": "2026-11-09T10:00:00Z", "headRefOid": "c0ffee"}}\n' > "$FAKE_GH_DIR/issues.json"
oitem() { "$P/adapters/local/create.sh" task "$1" --size S --body "x"; }
ostate() { "$P/adapters/local/read.sh" "$1" | jget "state.$2"; }
# ogate <item> <path>: one field of the item's entry in gate list --json; nothing when it has none.
ogate() { "$P/scripts/gate.sh" list --json | python3 -c 'import json,sys
item, path = sys.argv[1], sys.argv[2]
v = next(g for g in json.load(sys.stdin) if g["item"] == item)
for k in path.split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1" "$2" 2>/dev/null; }
orecord() { printf '%s/.flow/gates/%s.json' "$oroot/app" "$(item_slug "$1")"; }
opr() { python3 -c "import json,sys; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'][sys.argv[1]]=json.loads(sys.argv[2]); json.dump(d, open(p,'w'))" "$1" "$2"; }
hpass() { "$P/scripts/steward.sh" health >/dev/null 2>&1; }

OPTIONS='[{"label":"Keep the name","text":"Keep FooBar; callers depend on it.","recommended":false},{"label":"Rename","text":"Rename FooBar to Baz everywhere.","recommended":true}]'
oa="$(oitem 'Two names')"; "$P/adapters/local/write-state.sh" "$oa" step=implement
"$P/scripts/gate.sh" raise "$oa" ambiguity "**Keep the name or rename?**" --options "$OPTIONS" >/dev/null 2>&1
check "options: list --json gives back each option's label, text and recommended flag as raised" python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == json.loads(sys.argv[2])' "$(ogate "$oa" options)" "$OPTIONS"
for n in 0 3; do
  "$P/scripts/gate.sh" clear "$oa" --option "$n" >/dev/null 2>&1; code=$?
  check "clear --option $n on a gate with two options: refused, exit 2" [ "$code" -eq 2 ]
done
check "clear --option out of range: the gate stays for the owner" [ "$(ostate "$oa" gate)" = ambiguity ]
"$P/scripts/gate.sh" clear "$oa" --option 2 >/dev/null 2>&1
check "clear --option 2: the answer is the second option's text, not the first's" [ "$(ostate "$oa" answer)" = "Rename FooBar to Baz everywhere." ]
check "clear --option 2: the gate is cleared" [ "$(ostate "$oa" gate)" = none ]

ob="$(oitem 'A note with the pick')"; "$P/adapters/local/write-state.sh" "$ob" step=implement
"$P/scripts/gate.sh" raise "$ob" ambiguity "**Keep the name or rename?**" --options "$OPTIONS" >/dev/null 2>&1
"$P/scripts/gate.sh" clear "$ob" --option 1 "Mark it deprecated." >/dev/null 2>&1
check "clear --option with a note: the option's text leads and the note follows it" python3 -c 'import sys; answer = sys.argv[1]; assert answer.startswith("Keep FooBar; callers depend on it.") and answer.rstrip().endswith("Mark it deprecated."), answer' "$(ostate "$ob" answer)"

# A pick and a send-back are two answers; one clear carries one, in either order.
od="$(oitem 'A pick and a send-back')"; "$P/adapters/local/write-state.sh" "$od" step=implement
"$P/scripts/gate.sh" raise "$od" ambiguity "**Keep the name or rename?**" --options "$OPTIONS" >/dev/null 2>&1
for pick_and_back in "--option 1 --back Redo_it" "--back --option 1"; do
  # shellcheck disable=SC2086
  "$P/scripts/gate.sh" clear "$od" $pick_and_back >/dev/null 2>&1; code=$?
  check "clear $pick_and_back: an option with a send-back is refused, exit 2" [ "$code" -eq 2 ]
done
check "clear with an option and a send-back: the gate stays for the owner" [ "$(ostate "$od" gate)" = ambiguity ]

# Usage is the header comment block, however long it grows, and nothing of the code under it.
"$P/scripts/gate.sh" no-such-mode > "$work/gate-usage.out" 2>&1
check "gate.sh usage: exactly the header comment block, down to the first line of code" python3 -c 'import sys, itertools
header = list(itertools.takewhile(lambda line: line.startswith("#"), open(sys.argv[1]).read().splitlines()[1:]))
usage = open(sys.argv[2]).read().splitlines()
assert header and usage == header, (len(header), usage[-3:])' "$P/scripts/gate.sh" "$work/gate-usage.out"

oc="$(oitem 'Two recommended')"; "$P/adapters/local/write-state.sh" "$oc" step=implement
"$P/scripts/gate.sh" raise "$oc" ambiguity "**Which one?**" --options '[{"label":"A","text":"Do A.","recommended":true},{"label":"B","text":"Do B.","recommended":true}]' >/dev/null 2>&1
check "raise with two options both recommended: the gate still raises" [ "$(ostate "$oc" gate)" = ambiguity ]
check "raise with two options both recommended: it lists no options" [ "$(ogate "$oc" options)" = "[]" ]
"$P/scripts/gate.sh" clear "$oc" --option 1 >/dev/null 2>&1; code=$?
check "clear --option on a gate with no options: refused, exit 2" [ "$code" -eq 2 ]
"$P/scripts/gate.sh" clear "$oc" "Do A." >/dev/null 2>&1

# The option limit is _gates.py's MOST_OPTIONS: a gate raised with that many lists them all, one more lists none.
omost="$(sed -n 's/^FEWEST_OPTIONS, MOST_OPTIONS = [0-9][0-9]*, \([0-9][0-9]*\)$/\1/p' "$P/scripts/_gates.py")"
check "option limit read from _gates.py" [ -n "$omost" ]
ooptions() { python3 -c 'import json,sys; print(json.dumps([{"label": "Choice %d" % n, "text": "Do thing %d." % n, "recommended": n == 1} for n in range(1, int(sys.argv[1]) + 1)]))' "$1"; }
olimit="$(ooptions "$omost")"; oover="$(ooptions "$((omost + 1))")"
oo="$(oitem 'Many options')"; "$P/adapters/local/write-state.sh" "$oo" step=implement
"$P/scripts/gate.sh" raise "$oo" ambiguity "**Which of many?**" --options "$olimit" >/dev/null 2>&1
check "raise with as many options as the limit: it lists every one" python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == json.loads(sys.argv[2])' "$(ogate "$oo" options)" "$olimit"
"$P/scripts/gate.sh" clear "$oo" >/dev/null 2>&1
"$P/scripts/gate.sh" raise "$oo" ambiguity "**Which of too many?**" --options "$oover" >/dev/null 2>&1
check "raise with one option over the limit: it lists no options" [ "$(ogate "$oo" options)" = "[]" ]
"$P/scripts/gate.sh" clear "$oo" >/dev/null 2>&1

json_obj gate=escalation item=local:task/98 "message=Raised before 1.36." time=2026-10-24T10:00:00Z host=shell > .flow/gates/local-task-98.json
check "a record from an older flow lists an empty options array" [ "$(ogate local:task/98 options)" = "[]" ]
check "a record from an older flow lists no condition" [ "$(ogate local:task/98 condition)" = null ]
rm -f .flow/gates/local-task-98.json

od="$(oitem 'Who asks')"; "$P/adapters/local/write-state.sh" "$od" step=implement
"$P/scripts/gate.sh" raise "$od" escalation "**The run died three times.**" --raised-by "health job" >/dev/null 2>&1
check "raised_by: the --raised-by flag names who asked" [ "$(ogate "$od" raised_by)" = "health job" ]
"$P/scripts/gate.sh" clear "$od" >/dev/null 2>&1
"$P/scripts/gate.sh" raise "$od" ambiguity "**A or B?**" >/dev/null 2>&1
check "raised_by: with no flag and no run in flight, the item's step asked" [ "$(ogate "$od" raised_by)" = "step implement" ]
check "answered_by: an item mid-flow is answered by the step it resumes at" [ "$(ogate "$od" answered_by)" = "step implement" ]
check "board: a gate shows who raised it" sh -c "'$P/scripts/board.sh' | grep -q 'raised by step implement'"
check "board: a gate shows who carries its answer out" sh -c "'$P/scripts/board.sh' | grep -q 'answered by step implement'"
"$P/scripts/gate.sh" clear "$od" "A" >/dev/null 2>&1

oe="$(oitem 'Done, its PR open')"; "$P/adapters/local/write-state.sh" "$oe" step=done
"$P/adapters/local/link-pr.sh" "$oe" https://github.com/acme/widgets/pull/90
"$P/scripts/gate.sh" raise "$oe" ambiguity "**Rebase or merge?**" >/dev/null 2>&1
check "answered_by: a done item with an open PR is answered by the comments job" [ "$(ogate "$oe" answered_by)" = "comments job, next pass" ]
"$P/scripts/gate.sh" clear "$oe" >/dev/null 2>&1

# A gate that only waits on a blocker: health clears it once the blocker closes, the item keeps
# its step and runs it on the next pass, and nothing escalates the blocker.
oblock="$(oitem 'The blocker')"; ow="$(oitem 'Waits on the blocker')"
"$P/adapters/local/write-state.sh" "$ow" step=implement
"$P/scripts/gate.sh" raise "$ow" escalation "**Waits on $oblock.**" --condition "blocked_by:$oblock" >/dev/null 2>&1
check "condition: list --json gives back the condition the gate was raised with" [ "$(ogate "$ow" condition)" = "blocked_by:$oblock" ]
hpass
check "condition blocked_by: a health pass while the blocker is open keeps the gate" [ "$(ostate "$ow" gate)" = escalation ]
"$P/adapters/local/close.sh" "$oblock" >/dev/null 2>&1
ofile() { printf '%s/.flow/items/task/%s.md' "$oroot/app" "${1##*/}"; }
raised_before="$(grep -c ': \*\*Gate: ' "$(ofile "$ow")")"
hpass
check "condition blocked_by: one health pass after the blocker closes clears the gate" [ "$(ostate "$ow" gate)" = none ]
check "condition blocked_by: the cleared gate's record is gone" [ ! -f "$(orecord "$ow")" ]
check "condition blocked_by: the item keeps its step" [ "$(ostate "$ow" step)" = implement ]
check_all "condition blocked_by: the pass raises no new gate on the item for the closed blocker" '[ "$raised_before" -ge 1 ] && [ "$(grep -c ": \*\*Gate: " "$(ofile "$ow")")" = "$raised_before" ]'
check "condition blocked_by: the next pass hands the item out at its own step" [ "$("$P/scripts/next.sh" "$ow" --json 2>/dev/null | jget step)" = implement ]
"$P/scripts/steward.sh" release "$ow" --force >/dev/null 2>&1; rm -f .flow/runs/*.json

og="$(oitem 'Waits on nothing readable')"; "$P/adapters/local/write-state.sh" "$og" step=implement
"$P/scripts/gate.sh" raise "$og" escalation "**Waits on local:task/999.**" --condition "blocked_by:local:task/999" >/dev/null 2>&1
hpass
check "condition blocked_by: a blocker the tracker cannot read keeps the gate" [ "$(ostate "$og" gate)" = escalation ]
"$P/scripts/gate.sh" clear "$og" >/dev/null 2>&1

oh="$(oitem 'A condition outside the grammar')"; "$P/adapters/local/write-state.sh" "$oh" step=implement
"$P/scripts/gate.sh" raise "$oh" escalation "**Wait for the weekend.**" --condition "weekend:soon" >/dev/null 2>&1
check "condition outside the grammar: the gate still raises" [ "$(ostate "$oh" gate)" = escalation ]
check "condition outside the grammar: it is dropped" [ "$(ogate "$oh" condition)" = null ]
"$P/scripts/gate.sh" clear "$oh" --met "it ended" >/dev/null 2>&1; code=$?
check "clear --met on a gate with no condition: refused, exit 2" [ "$code" -eq 2 ]
check "clear --met on a gate with no condition: the gate stays" [ "$(ostate "$oh" gate)" = escalation ]
"$P/scripts/gate.sh" clear "$oh" >/dev/null 2>&1

# A blocked_by id is read through its adapter by the health job, outside any sandbox: only an id an
# adapter owns, in that adapter's shape, gets that far. The planted read.sh marks any run of it.
oplant="$work/gate-options-planted"; mkdir -p "$oplant"
printf '#!/bin/sh\ntouch "%s/ran"\necho "{\\"status\\": \\"closed\\"}"\n' "$oplant" > "$oplant/read.sh"; chmod +x "$oplant/read.sh"
oclimb="$(printf '../%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)${oplant#/}"
on="$(oitem 'A path for a blocker')"; "$P/adapters/local/write-state.sh" "$on" step=implement
"$P/scripts/gate.sh" raise "$on" escalation "**Waits on a path.**" --condition "blocked_by:$oclimb" >/dev/null 2>&1
check "condition blocked_by with a path for an id: the gate still raises" [ "$(ostate "$on" gate)" = escalation ]
check "condition blocked_by with a path for an id: it is dropped" [ "$(ogate "$on" condition)" = null ]
"$P/scripts/gate.sh" clear "$on" >/dev/null 2>&1
"$P/scripts/gate.sh" raise "$on" escalation "**Waits on a dotted local id.**" --condition "blocked_by:local:task/../../x" >/dev/null 2>&1
check "condition blocked_by with .. in a local id: it is dropped" [ "$(ogate "$on" condition)" = null ]
"$P/scripts/gate.sh" clear "$on" >/dev/null 2>&1
"$P/scripts/gate.sh" raise "$on" escalation "**Waits on an id no adapter owns.**" --condition "blocked_by:linear:ENG-4" >/dev/null 2>&1
check "condition blocked_by with an id no adapter owns: it is dropped" [ "$(ogate "$on" condition)" = null ]
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["condition"]=sys.argv[2]; json.dump(d, open(p,"w"))' "$(orecord "$on")" "blocked_by:$oclimb"
hpass
check "health on a record whose blocked_by is a path: the path's read.sh never runs" [ ! -f "$oplant/ran" ]
check "health on a record whose blocked_by is a path: the gate stays" [ "$(ostate "$on" gate)" = escalation ]
"$P/scripts/gate.sh" clear "$on" >/dev/null 2>&1
(. "$P/lib/flow.sh"; adapter read "$oclimb") >/dev/null 2>&1; code=$?
check "adapter with a path for an adapter name: refused, exit 2" [ "$code" -eq 2 ]
check "adapter with a path for an adapter name: the path's read.sh never runs" [ ! -f "$oplant/ran" ]
(. "$P/lib/flow.sh"; adapter read ..) >/dev/null 2>&1; code=$?
check "adapter with a leading-dot name and no slash: refused, exit 2" [ "$code" -eq 2 ]
"$P/scripts/gate.sh" raise "$on" escalation "**Waits on gh#772.**" --condition "blocked_by:gh#772" >/dev/null 2>&1
check "condition blocked_by with a GitHub issue id: the adapter owns it, so the gate keeps it" [ "$(ogate "$on" condition)" = "blocked_by:gh#772" ]
"$P/scripts/gate.sh" clear "$on" >/dev/null 2>&1

# A gh# blocker is read through the github adapter: the fake gh reports gh#772 closed.
ogh="$(oitem 'Waits on a GitHub issue')"; "$P/adapters/local/write-state.sh" "$ogh" step=implement
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["issues"].append({"number": 772, "title": "The GitHub blocker", "body": "", "state": "CLOSED", "labels": [], "url": "https://github.com/acme/widgets/issues/772"}); json.dump(d, open(p,"w"))' "$FAKE_GH_DIR/issues.json"
"$P/scripts/gate.sh" raise "$ogh" escalation "**Waits on gh#772.**" --condition "blocked_by:gh#772" >/dev/null 2>&1
hpass
check "condition blocked_by gh#: one health pass after GitHub reports the issue closed clears the gate" [ "$(ostate "$ogh" gate)" = none ]
check "condition blocked_by gh#: the item keeps its step" [ "$(ostate "$ogh" step)" = implement ]

oi="$(oitem 'A conflicting PR')"; "$P/adapters/local/write-state.sh" "$oi" step=done
"$P/adapters/local/link-pr.sh" "$oi" https://github.com/acme/widgets/pull/90
"$P/scripts/gate.sh" raise "$oi" escalation "**Resolve the conflict on #90.**" --condition "pr:#90 conflicting" >/dev/null 2>&1
opr mergeable '"UNKNOWN"'; hpass
check "condition pr conflicting: a PR GitHub has not judged yet (UNKNOWN) keeps the gate" [ "$(ostate "$oi" gate)" = escalation ]
opr mergeable '"MERGEABLE"'; hpass
check "condition pr conflicting: the PR merging cleanly again clears the gate" [ "$(ostate "$oi" gate)" = none ]
check "clear --met: an item at done keeps no answer waiting on a run" [ -z "$(ostate "$oi" answer_pending)" ]
"$P/scripts/gate.sh" clear "$oi" --met "pr:#90 conflicting" >/dev/null 2>&1; code=$?
check "clear --met on a gate already cleared: exit 0" [ "$code" -eq 0 ]

oj="$(oitem 'CI is down')"; "$P/adapters/local/write-state.sh" "$oj" step=done
"$P/adapters/local/link-pr.sh" "$oj" https://github.com/acme/widgets/pull/90
"$P/scripts/gate.sh" raise "$oj" escalation "**CI is down.**" --condition "ci:down" >/dev/null 2>&1
opr statusCheckRollup '[{"__typename": "CheckRun", "name": "test", "workflowName": "ci", "status": "COMPLETED", "conclusion": "FAILURE", "startedAt": "2026-11-09T10:00:00Z"}]'; hpass
check "condition ci:down: a failing check keeps the gate" [ "$(ostate "$oj" gate)" = escalation ]
"$P/scripts/gate.sh" clear "$oj" --met "pr:#90 conflicting" >/dev/null 2>&1; code=$?
check "clear --met naming another condition than the record's: refused, exit 1" [ "$code" -eq 1 ]
check "clear --met naming another condition than the record's: the gate stays" [ "$(ostate "$oj" gate)" = escalation ]
opr statusCheckRollup '[{"__typename": "CheckRun", "name": "test", "workflowName": "ci", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-09T11:00:00Z"}]'; hpass
check "condition ci:down: no failing check clears the gate" [ "$(ostate "$oj" gate)" = none ]

# Gates raised through advance.sh from a step's result file.
ok="$(oitem 'Gate from a result file')"
okj="$("$P/scripts/next.sh" "$ok" --json 2>/dev/null)"; okr="$(printf '%s' "$okj" | jget reports)"; okstep="$(printf '%s' "$okj" | jget step)"
python3 -c 'import json,sys; json.dump({"status": "gate", "gate": "ambiguity", "message": "**Keep the name or rename?**", "options": json.loads(sys.argv[1]), "condition": "ci:down"}, open(sys.argv[2], "w"))' "$OPTIONS" "$okr/$okstep.json"
"$P/scripts/advance.sh" "$ok" >/dev/null 2>&1
check "advance: a result file with options raises the gate with them" python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == json.loads(sys.argv[2])' "$(ogate "$ok" options)" "$OPTIONS"
check "advance: a result file with a condition raises the gate with it" [ "$(ogate "$ok" condition)" = "ci:down" ]
check "advance: the gate names the step that raised it" [ "$(ogate "$ok" raised_by)" = "step $okstep" ]
"$P/scripts/gate.sh" clear "$ok" "Rename." >/dev/null 2>&1; "$P/scripts/steward.sh" release "$ok" --force >/dev/null 2>&1; rm -f .flow/runs/*.json

ol="$(oitem 'Malformed options in a result file')"
olj="$("$P/scripts/next.sh" "$ol" --json 2>/dev/null)"; olr="$(printf '%s' "$olj" | jget reports)"; olstep="$(printf '%s' "$olj" | jget step)"
printf '{"status":"gate","gate":"ambiguity","message":"**A or B?**","options":[{"label":"","text":"Do A.","recommended":false}]}\n' > "$olr/$olstep.json"
"$P/scripts/advance.sh" "$ol" >/dev/null 2>&1; code=$?
check "advance: malformed options in a result file still stop at the gate (exit 4)" [ "$code" -eq 4 ]
check "advance: malformed options in a result file raise the gate with none" [ "$(ogate "$ol" options)" = "[]" ]
"$P/scripts/gate.sh" clear "$ol" "A." >/dev/null 2>&1; "$P/scripts/steward.sh" release "$ol" --force >/dev/null 2>&1; rm -f .flow/runs/*.json

# An escalation at step pr: the tracker comment carries the command the owner runs.
om="$(oitem 'Escalates at pr')"; "$P/adapters/local/write-state.sh" "$om" step=pr
omr="$("$P/scripts/next.sh" "$om" --json 2>/dev/null | jget reports)"
printf '{"status":"gate","gate":"escalation","message":"**The PR waits on local:task/772.**"}\n' > "$omr/pr.json"
"$P/scripts/advance.sh" "$om" >/dev/null 2>&1
check "escalation at step pr: the tracker comment names the gate.sh clear command for the owner" grep -q "gate.sh clear $om" "$(ofile "$om")"
check "escalation at step pr: the record keeps the message as raised, the command apart from it" [ "$(jget message < "$(orecord "$om")")" = "**The PR waits on local:task/772.**" ]
"$P/scripts/gate.sh" clear "$om" >/dev/null 2>&1; "$P/scripts/steward.sh" release "$om" --force >/dev/null 2>&1; rm -f .flow/runs/*.json

echo "a step with no result file (gh#169)"
# The session exits 0 but writes no <step>.json, as when every write is denied. That is a failed
# attempt on the item, not a silent stop the health job later undoes. Its own repo, so no
# claim or reservation left by an earlier section fills the pool.
mkdir -p "$work/noresult" && cd "$work/noresult" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
git worktree add -q -b main-wt-1 ../nr-wt-1 && git worktree add -q -b main-wt-2 ../nr-wt-2
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../nr-wt-1\n  - ../nr-wt-2\nnotify:\n  desktop: false\n' > .flow/config.yaml
nr="$("$P/scripts/new.sh" task "Ends with no result" --size S --body "## Acceptance
- [ ] n")"
FAKE_HOST=silent PATH="$cpath" "$P/templates/run-unattended.sh" claude "$nr" --max-steps 1 > "$work/noresult.out" 2>&1
check "a step whose session ends with no result file counts one failed attempt (gh#169)" [ "$("$P/adapters/local/read.sh" "$nr" | jget state.attempts)" = 1 ]
# The silent stub's last message, as the stub above prints it.
silent_last='Every write was denied, so no report was written.'
nr_file=".flow/items/$(printf '%s' "${nr#local:}").md"
check "a step whose session ends with no result file comments the session's last message on the item (gh#169)" grep -qF "$silent_last" "$nr_file"
# A Codex session a dropped stream stops: its error comes after its last agent message.
printf '%s\n' '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"reading the code"}}' \
  '{"type":"error","message":"stream disconnected before completion"}' > "$work/codex-drop.out"
: > "$work/codex-drop.err"
python3 -I "$P/scripts/_host.py" codex "$work/codex-drop.out" "$work/codex-drop.err" 1 "$work/codex-drop.sum" > "$work/codex-drop.stdout" 2>/dev/null
check "a codex session that ends on an error has that error as its last message, because the comment and the gate quote why it stopped (gh#169)" [ "$(jget last < "$work/codex-drop.sum")" = "stream disconnected before completion" ]
check "a codex session's error stays off stdout, because stdout is what the session printed (gh#169)" [ "$(cat "$work/codex-drop.stdout")" = "reading the code" ]
printf '%s' '{"type":"result","subtype":"success","is_error":true,"result":"You'"'"'ve hit your 5-hour limit \u00b7 resets 5:10am (Europe/London)"}' > "$work/window.out"
: > "$work/window.err"
python3 -I "$P/scripts/_host.py" claude "$work/window.out" "$work/window.err" 1 "$work/window.sum" >/dev/null 2>&1
check "ClaudeTimedUsageWindow_ReportsSpendLimit: a retry before the window resets fails the same way" [ "$(jget cause < "$work/window.sum")" = spend-limit ]
# Three silent sessions in a row on a fresh item: the attempt limit from profiles.json.
max_attempts="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_attempts"])' "$P/profiles.json")"
ng="$("$P/scripts/new.sh" task "Ends with no result, every time" --size S --body "## Acceptance
- [ ] g")"
n=1
while [ "$n" -lt "$max_attempts" ]; do
  FAKE_HOST=silent PATH="$cpath" "$P/templates/run-unattended.sh" claude "$ng" --max-steps 1 >> "$work/noresult-gate.out" 2>&1
  n=$((n + 1))
done
check "a silent session short of the attempt limit raises no gate (gh#169)" [ "$("$P/adapters/local/read.sh" "$ng" | jget state.gate)" = none ]
FAKE_HOST=silent PATH="$cpath" "$P/templates/run-unattended.sh" claude "$ng" --max-steps 1 >> "$work/noresult-gate.out" 2>&1
check "the silent session that reaches the attempt limit raises the escalation gate (gh#169)" [ "$("$P/adapters/local/read.sh" "$ng" | jget state.gate)" = escalation ]
check_all "the escalation gate for a silent session quotes its last message (gh#169)" 'jget message < ".flow/gates/$(item_slug "$ng").json" | grep -qF "$silent_last"'
check "a silent session that reaches the escalation gate keeps its claim (gh#169)" sh -c "[ -f \"\$('$P/scripts/steward.sh' find '$ng')/.flow/claim.json\" ]"
# Health releases a claim that holds nothing and has been quiet past jobs.health.grace. A short
# grace and a wait past it put the item from the first check in that window.
printf 'jobs:\n  health:\n    grace: 1s\n' >> .flow/config.yaml
nr_wt="$("$P/scripts/steward.sh" find "$nr")"
sleep 2
: > "$work/noresult-procs"
FLOW_HEALTH_PROCS="$work/noresult-procs" "$P/jobs/health.sh" claude > "$work/noresult-health.out" 2>&1
check "the health job keeps the claim of an item whose last run ended with no result (gh#169)" [ -f "$nr_wt/.flow/claim.json" ]

[ "$fails" -eq 0 ] && { echo "gate-options: ok"; exit 0; }
echo "gate-options: $fails failed"; exit 1
