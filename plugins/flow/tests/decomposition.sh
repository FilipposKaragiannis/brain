#!/bin/sh
# decomposition.sh: a split parent and its children.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
. "$here/_jobs_fixture.sh"
. "$here/_claimed_worktree_fixture.sh"
. "$here/_fake_curl_fixture.sh"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pr"]={"number":90,"state":"OPEN","isDraft":False,"mergedAt":None,"url":"https://gh/pull/90","headRefName":"","headRefOid":"","baseRefName":"main"}; json.dump(d,open(p,"w"))' "$FAKE_GH_DIR/issues.json"
echo "decomposition: a split parent and its children"
mkdir -p "$work/split" && cd "$work/split" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init
for n in 1 2 3; do git worktree add -q --detach "../app-wt-$n"; done
mkdir -p .flow && printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../app-wt-1\n  - ../app-wt-2\n  - ../app-wt-3\nnotify:\n  desktop: false\n' > .flow/config.yaml
export FLOW_HEALTH_PROCS="$work/split.procs"; : > "$FLOW_HEALTH_PROCS"
sread() { "$P/adapters/local/read.sh" "$1" | jget "$2"; }
# plan_step <item> <mode> <status json> <child>...: run the item's plan step: plan.md in <mode>,
# the children made with --parent, the result file written; prints the worktree. advance is left
# to the caller.
plan_step() {
  ps_item="$1"; ps_mode="$2"; ps_result="$3"; shift 3
  "$P/adapters/local/write-state.sh" "$ps_item" step=plan >/dev/null
  ps_out="$("$P/scripts/next.sh" "$ps_item" --json)"; ps_rep="$(printf '%s' "$ps_out" | jget reports)"
  printf '# plan\nDecomposition: %s\n' "$ps_mode" > "$ps_rep/plan.md"
  for ps_kid in "$@"; do "$P/scripts/new.sh" task "$ps_kid" --size S --parent "$ps_item" --body x >/dev/null 2>&1; done
  printf '%s\n' "$ps_result" > "$ps_rep/plan.json"
  printf '%s' "$ps_out" | jget worktree
}
par="$("$P/scripts/new.sh" task "Split me" --size M --priority P1 --area Bots --body x)"
wp="$(plan_step "$par" "tracker tasks (each phase is a PR)" '{"status":"gate","gate":"decomposition","message":"Two children."}')"
printf 'adr\n' > "$wp/adr.md" && git -C "$wp" add adr.md && git -C "$wp" commit -qm "docs: the ADR the children need"
k1="$("$P/scripts/new.sh" task "Child one" --size S --parent "$par" --body x 2>"$work/split.err")"
k2="$("$P/scripts/new.sh" task "Child two" --size S --priority P0 --parent "$par" --body x 2>/dev/null)"
check "new: a child takes its parent's priority and area" [ "$(sread "$k1" priority) $(sread "$k1" area)" = "P1 Bots" ]
check "new: the inheritance is said on stderr" grep -q "$k1 takes priority P1, area Bots from its parent $par" "$work/split.err"
check "new: a child that names its own priority keeps it, and still takes the area" [ "$(sread "$k2" priority) $(sread "$k2" area)" = "P0 Bots" ]
check "local: an item counts its open children" [ "$(sread "$par" open_children)" = 2 ]
"$P/scripts/advance.sh" "$par" > "$work/split.out" 2>&1; code=$?
check "split: a plan step ending in tracker tasks with children splits the item (exit 4)" sh -c "[ $code -eq 4 ] && [ \"\$('$P/adapters/local/read.sh' '$par' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; print(s[\"step\"], s[\"gate\"])')\" = 'split decomposition' ]"
check "split: the decomposition gate tells the owner how to keep it whole" grep -q 'To keep it whole instead, close its children, then clear the gate' .flow/gates/local-task-1.json
check "split: the parent's clean worktree goes back to the pool" sh -c "[ ! -f '$wp/.flow/claim.json' ] && [ -z \"\$('$P/scripts/steward.sh' find '$par')\" ] && [ -z \"\$('$P/adapters/local/read.sh' '$par' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"worktree\"])')\" ]"
check "split: a branch with commits past the base is kept, and the event says so" sh -c "git show-ref --verify --quiet refs/heads/flow/local-task-1 && grep -q '	$par	split	.*released app-wt-1; flow/local-task-1 keeps its 1 commit(s) past main' .flow/events.log"
check "split: the parent is commented on" grep -q 'Split: split into 2 open child item(s)' .flow/items/task/1.md
"$P/scripts/gate.sh" clear "$par" "go" > "$work/split.out" 2>&1
check "split: clearing the gate with children open leaves it split" sh -c "[ \"\$('$P/adapters/local/read.sh' '$par' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = split ] && grep -q 'run next' '$work/split.out'"
"$P/scripts/next.sh" "$par" > /dev/null 2> "$work/split.err"; code=$?
check "split: next on the parent waits on its children (exit 4)" sh -c "[ $code -eq 4 ] && grep -q 'is split and waits on its 2 open child item(s)' '$work/split.err'"
check "split: the parent is never ready, the children are" sh -c "'$P/adapters/local/list-ready.sh' | python3 -c 'import json,sys; ids=[i[\"id\"] for i in json.load(sys.stdin)]; assert \"$par\" not in ids and \"$k1\" in ids and \"$k2\" in ids, ids'"
check "board: a split parent shows it waits on its children, not plan" sh -c "'$P/scripts/board.sh' | grep -q '| $par | task | P1 | M | Split me | split, waiting on 2 children |'"
"$P/adapters/local/close.sh" "$k1" >/dev/null; "$P/adapters/local/close.sh" "$k2" >/dev/null
"$P/scripts/next.sh" "$par" > /dev/null 2> "$work/split.err"; code=$?
check "split: once every child is closed, next says to close the parent (exit 6)" sh -c "[ $code -eq 6 ] && grep -q 'every child is closed' '$work/split.err'"
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1; "$P/scripts/steward.sh" health >> "$work/split.out" 2>&1
check "health: a split parent with every child closed is said once" sh -c "[ \"\$(grep -c '$par: split, and every child is closed: close it' '$work/split.out')\" = 1 ]"
# The owner keeps a split item whole: closes the children, then clears the gate.
wh="$("$P/scripts/new.sh" task "Keep me whole" --size M --body x)"
plan_step "$wh" "tracker tasks" '{"status":"gate","gate":"decomposition","message":"One child."}' "Whole child" >/dev/null
"$P/scripts/advance.sh" "$wh" >/dev/null 2>&1
"$P/adapters/local/close.sh" "$(grep -l 'title: Whole child' .flow/items/task/*.md | sed 's|.*/\([0-9]*\)\.md|local:task/\1|')" >/dev/null
check "split: an owner who closed the children and cleared the gate gets the plan step back" sh -c "'$P/scripts/gate.sh' clear '$wh' 'keep it whole' | grep -q 'whole again' && [ \"\$('$P/adapters/local/read.sh' '$wh' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = plan ]"
wwh="$("$P/scripts/steward.sh" claim "$wh")"
"$P/scripts/new.sh" task "Follow-up of a whole item" --size S --parent "$wh" --body x >/dev/null 2>&1
"$P/scripts/steward.sh" health >/dev/null 2>&1
check "split: a kept-whole item with its old tracker-tasks plan and a new child is not split again" sh -c "[ -f '$wwh/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$wh' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = plan ] && '$P/scripts/steward.sh' split '$wh' | grep -q 'the owner kept it whole'"
wout="$("$P/scripts/next.sh" "$wh" --json)"; wrep="$(printf '%s' "$wout" | jget reports)"
printf '# plan\nDecomposition: tracker tasks (rewritten after the owner kept it whole)\n' > "$wrep/plan.md"
printf '{"status":"done","summary":"two PRs after all"}\n' > "$wrep/plan.json"
"$P/scripts/advance.sh" "$wh" >/dev/null 2>&1
check "split: once the plan step rewrites plan.md the mark is gone and the split stands" [ "$(sread "$wh" state.step)" = split ]
am="$("$P/scripts/new.sh" task "Asks first" --size M --body x)"
wam="$(plan_step "$am" "tracker tasks" '{"status":"gate","gate":"ambiguity","message":"1. Which base?"}' "Asking child")"
"$P/scripts/advance.sh" "$am" >/dev/null 2>&1
check "split: a plan step stopping at an ambiguity gate does not split" sh -c "[ -f '$wam/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$am' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; print(s[\"step\"], s[\"gate\"])')\" = 'plan ambiguity' ]"
"$P/scripts/gate.sh" clear "$am" "main" >/dev/null 2>&1; "$P/scripts/steward.sh" release "$am" --force >/dev/null 2>&1
# A child filed by hand and a plan in local phases (the gate raised before the planner made any):
# the owner's answer "keep it whole" never splits it.
lp="$("$P/scripts/new.sh" task "Local phases" --size M --body x)"
wl="$(plan_step "$lp" "local phases" '{"status":"gate","gate":"decomposition","message":"Approve the split before the items are created."}' "Stray follow-up")"
"$P/scripts/advance.sh" "$lp" >/dev/null 2>&1
"$P/scripts/gate.sh" clear "$lp" "keep it whole" >/dev/null 2>&1
check "split: children exist but the plan is not tracker tasks and the owner said keep it whole: not split" sh -c "[ -f '$wl/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$lp' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = plan ]"
check "split: the steward refuses a plan that is not tracker tasks" sh -c "! '$P/scripts/steward.sh' split '$lp' | grep -q released && '$P/scripts/steward.sh' split '$lp' | grep -q 'does not say tracker tasks'"
"$P/scripts/steward.sh" release "$lp" --force >/dev/null 2>&1
# A dirty worktree is never reset: it stays claimed, the claim says split, and the event says why.
dp="$("$P/scripts/new.sh" task "Dirty split" --size M --body x)"
wd="$(plan_step "$dp" "tracker tasks" '{"status":"done","summary":"two PRs"}' "Dirty child")"
printf 'wip\n' > "$wd/wip.txt"
"$P/scripts/advance.sh" "$dp" >/dev/null 2>&1; code=$?
check "split: a plan step done in tracker tasks splits with no gate (exit 4)" sh -c "[ $code -eq 4 ] && [ \"\$('$P/adapters/local/read.sh' '$dp' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; print(s[\"step\"], s[\"gate\"])')\" = 'split none' ]"
check "split: a dirty worktree is kept, its change untouched, the claim says split, and the event says why" sh -c "[ -f '$wd/wip.txt' ] && [ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"step\"])' '$wd/.flow/claim.json')\" = split ] && grep -q '	$dp	split	.*is kept: it has uncommitted changes' .flow/events.log"
lines="$(grep -c "	$dp	split	" .flow/events.log)"
"$P/scripts/steward.sh" split "$dp" >/dev/null; "$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "split: asking again while still dirty says nothing new" [ "$(grep -c "	$dp	split	" .flow/events.log)" = "$lines" ]
rm "$wd/wip.txt"
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "health: a split whose worktree is clean now is released" sh -c "[ ! -f '$wd/.flow/claim.json' ] && grep -q '$dp: split into 1 open child item(s), it waits on them; released' '$work/split.out'"
# A live session in the worktree keeps it.
lv="$("$P/scripts/new.sh" task "Live session" --size M --body x)"
wv="$(plan_step "$lv" "tracker tasks" '{"status":"done","summary":"x"}' "Live child")"
printf '4242\t%s\tclaude\n' "$wv" > "$FLOW_HEALTH_PROCS"
"$P/scripts/advance.sh" "$lv" >/dev/null 2>&1
check "split: a worktree a live session works in is kept" sh -c "[ -f '$wv/.flow/claim.json' ] && grep -q '	$lv	split	.*is kept: a session works in it' .flow/events.log"
: > "$FLOW_HEALTH_PROCS"; "$P/scripts/steward.sh" health >/dev/null 2>&1
check "health: once the session is gone the split is released" [ ! -f "$wv/.flow/claim.json" ]
# A parent split before 1.19.0: step plan, the gate long cleared, still claimed.
op="$("$P/scripts/new.sh" task "Old split" --size M --body x)"
wo="$(plan_step "$op" "tracker tasks" '{"status":"done"}' "Old child")"
rm -f .flow/runs/local-task-*.json
"$P/adapters/local/write-state.sh" "$op" step=plan gate=none answered=decomposition
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "health: a parent split before 1.19.0 is finished: step split, worktree released" sh -c "[ ! -f '$wo/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$op' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = split ]"
# An item at implement with the decomposition answer left over and a follow-up child: untouched.
fp="$("$P/scripts/new.sh" task "Has a follow-up" --size M --body x)"
wf="$(plan_step "$fp" "tracker tasks" '{"status":"done"}')"
rm -f .flow/runs/local-task-*.json
"$P/adapters/local/write-state.sh" "$fp" step=implement answered=decomposition
"$P/scripts/new.sh" task "Follow-up" --size S --parent "$fp" --body x >/dev/null 2>&1
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "health: an item at implement with a follow-up child is not split" sh -c "[ -f '$wf/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$fp' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = implement ]"
# The implement step finds open children in tracker-tasks mode: it splits, and advance keeps it split.
"$P/scripts/next.sh" "$fp" >/dev/null 2>&1
"$P/scripts/steward.sh" split "$fp" > "$work/split.out" 2>&1
check "split: during a run the worktree stays" sh -c "[ -f '$wf/.flow/claim.json' ] && grep -q 'is kept: a run is in flight' '$work/split.out'"
"$P/scripts/advance.sh" "$fp" --status done --summary "the children are open" >/dev/null 2>&1; code=$?
check "split: the implement step's result does not move a split item, and the run's end releases it" sh -c "[ $code -eq 4 ] && [ ! -f '$wf/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$fp' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = split ]"
# Under a gate: uncommitted changes, and threads awaiting a reply at the merge gate, are said once.
mg="$("$P/scripts/new.sh" task "At the merge gate" --size S --body x)"; wm="$("$P/scripts/steward.sh" claim "$mg")"
"$P/adapters/local/write-state.sh" "$mg" step=pr gate=merge pr=https://gh/pull/90
printf 'half a fix\n' > "$wm/half.txt"
python3 - "$FAKE_GH_DIR/issues.json" <<'PY4'
import json, sys
d = json.load(open(sys.argv[1])); d["pr"] = d.get("pr") or {}; d["pr"].update(number=90, state="OPEN", updatedAt="2026-10-25T00:00:00Z", headRefOid="abc", mergeable="MERGEABLE")
d["threads"] = [{"id": "T_7", "isResolved": False, "isOutdated": False, "path": "src/RodAgent.cs", "line": 3,
                 "comments": {"nodes": [{"databaseId": 701, "body": "The carry walk drops the ball.", "author": {"login": "chatgpt-codex-connector"}, "createdAt": "t"}]}}]
json.dump(d, open(sys.argv[1], "w"))
PY4
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1; "$P/scripts/steward.sh" health >> "$work/split.out" 2>&1
check "health: a gated item with uncommitted changes is said once, the changes untouched" sh -c "[ \"\$(grep -c '$mg: waits at the merge gate with uncommitted changes in app-wt-' '$work/split.out')\" = 1 ] && [ -f '$wm/half.txt' ]"
check "health: threads awaiting a reply at the merge gate are said once" sh -c "[ \"\$(grep -c '$mg: PR #90 has 1 unresolved review thread(s) awaiting a reply while $mg waits at the merge gate' '$work/split.out')\" = 1 ]"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads']=[]; json.dump(d, open(p,'w'))"
# At the merge gate, a PR still in review waits on its reviewers, not on the owner.
mgate=".flow/gates/$(item_slug "$mg").json"
printf '{"item":"%s","gate":"merge","message":"Merge the PR","time":"2026-10-01T00:00:00Z","host":"t"}\n' "$mg" > "$mgate"
review_pr() { # review_pr <decision> <codex reply or -> [<latest review state>]: one @codex request two hours old
  python3 - "$FAKE_GH_DIR/issues.json" "$@" <<'PY5'
import json, sys, time
p, decision, reply = sys.argv[1], sys.argv[2], sys.argv[3]
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
asked = time.time() - 7200
owner, codex = {"login": "owner", "type": "User"}, {"login": "chatgpt-codex-connector[bot]", "type": "Bot"}
d = json.load(open(p)); pr = d["pr"]
pr.update(reviewDecision=decision, latestReviews=[{"state": s} for s in sys.argv[4:]], reviewRequests=[], reviews=[], timeline=[])
pr["rest_comments"] = [{"id": 7, "user": owner, "body": "@codex please review", "created_at": iso(asked), "updated_at": iso(asked), "reactions": {}}]
if reply != "-":
    pr["rest_comments"].append({"id": 8, "user": codex, "body": reply, "created_at": iso(asked + 60), "updated_at": iso(asked + 60), "reactions": {}})
json.dump(d, open(p, "w"))
PY5
}
review_pr "" -
: > "$work/offline.log"
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1
check "health: a PR at the merge gate with a reviewer yet to answer is in review, not at the gate" sh -c "grep -q '1 in review)' '$work/review.out' && grep -q '\"state\": \"in-review\"' .flow/reviews/90.review.json && grep -q '\"waiting\": \\[\"codex\"\\]' .flow/reviews/90.review.json"
check "health: no merge reminder while the PR is in review" sh -c "! grep -q '$mg: waiting .* at the merge gate' '$work/review.out'"
review_pr CHANGES_REQUESTED "No issues found."
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1
check "health: a PR with changes requested is not at the merge gate" sh -c "grep -q '1 in review)' '$work/review.out' && grep -q '\"state\": \"changes-requested\"' .flow/reviews/90.review.json && ! grep -q '$mg: waiting .* at the merge gate' '$work/review.out'"
review_pr "" "No issues found." CHANGES_REQUESTED
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1
check "health: a latest review requesting changes counts when GitHub gives no decision" grep -q '"state": "changes-requested"' .flow/reviews/90.review.json
review_pr "" "No issues found."
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1
check "health: once every reviewer answered, the PR is at the merge gate and the owner is reminded" sh -c "! grep -q 'in review)' '$work/review.out' && grep -q '\"state\": \"ready\"' .flow/reviews/90.review.json && grep -q '$mg: waiting .* at the merge gate' '$work/review.out'"
# GitHub tracks a Copilot request, so the live request list decides; its timeline misses a removal.
printf '{"reviewer": "copilot", "answered": false}\n{"reviewer": "codex", "answered": true}\n' > "$work/rows.jsonl"
check "health: a Copilot request the owner removed does not hold the PR in review" sh -c "python3 '$P/scripts/_health.py' review '{\"reviewDecision\": \"\", \"reviewRequests\": []}' '$work/rows.jsonl' | grep -qx 'state	ready'"
check "health: a live Copilot request holds the PR in review" sh -c "python3 '$P/scripts/_health.py' review '{\"reviewDecision\": \"\", \"reviewRequests\": [{\"login\": \"Copilot\"}]}' '$work/rows.jsonl' | grep -qx 'state	in-review'"
review_pr "" "To use Codex here, create an environment for this repo."
rm -f .flow/health/*.remind; : > "$work/curl.log"
for run in 1 2; do PATH="$work/fakebin:$PATH" FLOW_SLACK_WEBHOOK=https://env.example/hook "$P/scripts/steward.sh" health; done > "$work/review.out" 2>&1
check "health: a reviewer that cannot review is told to the owner once, at the merge gate" sh -c "[ \"\$(grep -c '$mg: codex cannot review PR #90: it replied \"To use Codex here, create an environment for this repo.\"' '$work/review.out')\" = 1 ] && [ \"\$(grep -c 'cannot review PR' '$work/curl.log')\" = 1 ] && grep -q '$mg: waiting .* at the merge gate' '$work/review.out'"
check "health: the review record names the reviewer that cannot review" grep -q '"cannot": \[{"reviewer": "codex"' .flow/reviews/90.review.json
# A closed item's merge gate is a defect, even with its PR in review and its dirty worktree kept.
review_pr "" -
mg_file=".flow/items/task/${mg##*/}.md"
"$P/adapters/local/close.sh" "$mg" >/dev/null
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1
check "HealthGates_ClosedItemMergeGateInReview_SaidAsADefect: a closed item's merge gate with its PR in review is a defect, not a gate waiting on the reviewers" sh -c "grep -q '^$mg: defect: closed with its merge gate still open' '$work/review.out' && ! grep -q 'in review)' '$work/review.out' && [ -f '$wm/half.txt' ] && [ -f '$wm/.flow/claim.json' ]"
check "HealthClaim_ClosedItemMergeGateInReview_KeepsNoReviewRecord: the closed item's PR gets no review record the console would show as in review" [ ! -f .flow/reviews/90.review.json ]
sed 's/^status: closed$/status: open/; /^closed: /d' "$mg_file" > "$mg_file.tmp" && mv "$mg_file.tmp" "$mg_file"
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1 # reopened: its review record is back for the check below
"$P/adapters/local/write-state.sh" "$mg" gate=none; rm -f "$mgate"
"$P/scripts/steward.sh" health > "$work/review.out" 2>&1
check "health: the review record goes once the PR leaves the merge gate" [ ! -f .flow/reviews/90.review.json ]
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); [d['pr'].pop(k, None) for k in ('reviewDecision','latestReviews','reviewRequests','rest_comments','reviews','timeline')]; json.dump(d, open(p,'w'))"
"$P/adapters/local/write-state.sh" "$mg" gate=merge
# A worktree left dirty by a pass cut off before 1.19.0 (no note): the next pass is told to continue.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName='flow/gh-77', updatedAt='2026-10-25T01:00:00Z'); json.dump(d, open(p,'w'))"
mkdir -p "$wm/.flow/reports" && printf '{"item":"gh#77","branch":"flow/gh-77","base":"main"}\n' > "$wm/.flow/claim.json"
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "%s/host77.log"\n' "$work" > "$work/bin/claude"; chmod +x "$work/bin/claude"
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: uncommitted changes with no note get one, and the pass is told to read it" sh -c "grep -q '90: .*holds uncommitted changes from an earlier run' .flow/log/comments.log && grep -q 'An earlier pass was cut short: read .*gh-77/comments-resume.md first' '$work/host77.log' && [ -f '$wm/.flow/reports/gh-77/comments-resume.md' ]"
check "comments job: a pass that completes with the tree still dirty keeps the note" [ -f "$wm/.flow/reports/gh-77/comments-resume.md" ]
check "CommentsJob_ItemHoldsAWorktree_PassStartsInIt: the pass's session starts in the item's worktree, the one place a sandboxed Claude session can commit" sh -c "[ \"\$(cd \"\$(head -1 '$work/host77.log' | cut -f2)\" && pwd -P)\" = \"\$(cd '$wm' && pwd -P)\" ]"
rm "$wm/half.txt"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: a pass that completes with a clean tree removes the note" [ ! -f "$wm/.flow/reports/gh-77/comments-resume.md" ]
# Another session in the item's worktree: the job never edits under it, named or not.
printf '4242\t%s\tclaude --resume\n' "$wm" > "$FLOW_HEALTH_PROCS"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(updatedAt='2026-10-25T01:30:00Z'); json.dump(d, open(p,'w'))"
: > "$work/host77.log"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: an item whose worktree another session works in is skipped, and the log says which" sh -c "[ ! -s '$work/host77.log' ] && grep -q '90: another session works in .*app-wt-.* (claude process 4242), skipped' .flow/log/comments.log && tail -1 .flow/log/comments.log | grep -q 'quiet: 1 in use: 90 (claude process 4242 in app-wt-[0-9]*)\$'"
check "comments job: the owner is told the item, the PR, the worktree and what works there" grep -q 'comments-skipped	gh#77: the comments job skips PR #90 while claude process 4242 works in .*app-wt-.*; if nobody uses it, end it: kill 4242\.' .flow/events.log
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: the owner is told once while the session stays in the worktree" [ "$(grep -c '	comments-skipped	' .flow/events.log)" = 1 ]
: > "$FLOW_HEALTH_PROCS"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: once that session ends, the pass runs" grep -q 'comments 90' "$work/host77.log"
printf '4242\t%s\tclaude --resume\n' "$wm" > "$FLOW_HEALTH_PROCS"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: a session back in the worktree after a pass addressed the PR is told again" [ "$(grep -c '	comments-skipped	' .flow/events.log)" = 2 ]
: > "$FLOW_HEALTH_PROCS"
# A PR from a local item's branch (flow/local-task-1) names its item too, so it is skipped the same way.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName='flow/$(item_slug "$mg")', updatedAt='2026-10-25T01:45:00Z'); json.dump(d, open(p,'w'))"
printf '{"item":"%s","branch":"flow/%s","base":"main"}\n' "$mg" "$(item_slug "$mg")" > "$wm/.flow/claim.json"
printf '4242\t%s\tclaude --resume\n' "$wm" > "$FLOW_HEALTH_PROCS"
: > "$work/host77.log"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: a PR from a local item's branch whose worktree another session works in is skipped" sh -c "[ ! -s '$work/host77.log' ] && tail -2 .flow/log/comments.log | grep -q '90: another session works in .*app-wt-.* (claude process 4242), skipped'"
# The item and its PR's number name one PR, so they share the in-use marker: told once, cleared by either.
told="$(grep -c '	comments-skipped	' .flow/events.log)"
"$P/jobs/comments.sh" claude "$mg" >/dev/null 2>&1
check "comments job: a run named by the item after one named by its PR number tells the owner nothing new" [ "$(grep -c '	comments-skipped	' .flow/events.log)" = "$told" ]
: > "$FLOW_HEALTH_PROCS"; "$P/jobs/comments.sh" claude "$mg" >/dev/null 2>&1
printf '4242\t%s\tclaude --resume\n' "$wm" > "$FLOW_HEALTH_PROCS"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: a pass named by the item clears the marker a run named by the PR number reads" [ "$(grep -c '	comments-skipped	' .flow/events.log)" = "$((told + 1))" ]
check "comments job: the in-use marker is keyed by the PR number" sh -c "ls .flow/log/comments.seen/ | grep -qx 'pr-90.told-in-use' && ! ls .flow/log/comments.seen/ | grep -q '^90.told-in-use'"
# A person's session idle past jobs.comments.idle_session holds a worktree with nothing uncommitted
# no longer; with an uncommitted change in it the pass still stays out.
mkdir -p "$HOME/.claude/sessions"
python3 -c 'import json, sys, time; json.dump({"pid": 4242, "cwd": sys.argv[1], "status": "idle", "statusUpdatedAt": int((time.time() - 7200) * 1000)}, open(sys.argv[2], "w"))' "$wm" "$HOME/.claude/sessions/4242.json"
: > "$work/host77.log"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "IdleSessionInACleanWorktree_PassRuns: a session idle two hours with nothing uncommitted leaves no work the pass could edit under" grep -q 'comments 90' "$work/host77.log"
printf 'theirs\n' > "$wm/uncommitted.txt"
: > "$work/host77.log"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "IdleSessionInAWorktreeWithUncommittedWork_PassStaysOut: the change may be the person's, so the pass does not edit under it" [ ! -s "$work/host77.log" ]
: > "$work/host77.log"; GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=status.showUntrackedFiles GIT_CONFIG_VALUE_0=no "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "IdleSessionBesideAnUntrackedFileTheGitConfigHides_PassStaysOut: the file is the person's work all the same" [ ! -s "$work/host77.log" ]
rm -f "$wm/uncommitted.txt"
slot_keeper="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/comments.sh")"
mkdir -p .flow/log/comments.slots && ln -sfn "$slot_keeper" .flow/log/comments.slots/1
: > "$work/host77.log"; mark_comments_log
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1 & slot_waiting_run=$!
wait_for comments_logged_since_mark '90: waits for a free pass slot'
python3 -c 'import json, sys, time; json.dump({"pid": 4242, "cwd": sys.argv[1], "status": "busy", "statusUpdatedAt": int(time.time() * 1000)}, open(sys.argv[2], "w"))' "$wm" "$HOME/.claude/sessions/4242.json"
kill "$slot_keeper" 2>/dev/null; wait "$slot_waiting_run"
check "IdleSessionResumedWhileThePassWaitsForASlot_PassStaysOut: the person is back at work in the worktree" [ ! -s "$work/host77.log" ]
rm -f "$HOME/.claude/sessions/4242.json"
: > "$FLOW_HEALTH_PROCS"; printf '{"item":"gh#77","branch":"flow/gh-77","base":"main"}\n' > "$wm/.flow/claim.json"
# P2-7: a reports folder in a worktree another item holds gets no dirty-tree note.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName='flow/gh-78', updatedAt='2026-10-25T02:00:00Z'); json.dump(d, open(p,'w'))"
mkdir -p "$wm/.flow/reports/gh-78" && printf 'other work\n' > "$wm/other.txt"
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: no dirty-tree note when the worktree's claim names another item" sh -c "[ ! -f '$wm/.flow/reports/gh-78/comments-resume.md' ] && ! grep -q 'gh-78/comments-resume.md' '$work/host77.log'"
rm -f "$wm/other.txt"
# A PR head the branch template named maps to its item through the claim that holds it, from any tracker.
templated_local_bug="$("$P/adapters/local/create.sh" bug "Stuck ball" --body x)"
mv "$work/bin/claude" "$work/claude-logging-only"
cat > "$work/bin/claude" <<EOF
#!/bin/sh
printf '%s\t%s\t%s\n' "\$0" "\$PWD" "\$*" >> "$work/host77.log"
: > pass-ran
resume_note="\$(printf '%s' "\$*" | sed -n 's/.*read \(.*comments-resume\.md\) first.*/\1/p')"
[ -z "\$resume_note" ] || cp "\$resume_note" continued-note.md
EOF
chmod +x "$work/bin/claude"
for templated_row in "jira:PROJ-123 task/proj-123-drill-timer 2026-10-25T02:10:00Z" "$templated_local_bug bugfix/12-x 2026-10-25T02:20:00Z"; do
  templated_item="${templated_row%% *}"; templated_rest="${templated_row#* }"; templated_head="${templated_rest% *}"
  python3 -c "import json,sys; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName=sys.argv[1], updatedAt=sys.argv[2]); json.dump(d, open(p,'w'))" "$templated_head" "${templated_rest#* }"
  printf '{"item":"%s","branch":"%s","base":"main"}\n' "$templated_item" "$templated_head" > "$wm/.flow/claim.json"
  printf 'half done\n' > "$wm/half.txt"
  : > "$work/host77.log"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
  check "CommentsJob_TemplatedHead_PassStartsInTheWorktreeItsClaimHolds [$templated_head]: the head maps to $templated_item through its claim, so the pass's work lands where the item's work is" [ -f "$wm/pass-ran" ]
  check "CommentsJob_TemplatedHead_PassReadsTheItemsResumeNote [$templated_head]: the uncommitted work is noted in $templated_item's reports, so the pass continues from that note" cmp -s "$wm/.flow/reports/$(item_slug "$templated_item")/comments-resume.md" "$wm/continued-note.md"
  rm -f "$wm/half.txt" "$wm/pass-ran" "$wm/continued-note.md"; printf '{"item":"gh#77","branch":"flow/gh-77","base":"main"}\n' > "$wm/.flow/claim.json"
done
mv "$work/claude-logging-only" "$work/bin/claude"
git init -q --bare "$work/split-origin.git" && git remote add origin "$work/split-origin.git" && git push -q origin main 2>/dev/null
up="$("$P/scripts/new.sh" task "Pushed branch" --size S --body x)"; wu="$("$P/scripts/steward.sh" claim "$up")"; bu="$(git -C "$wu" symbolic-ref --short HEAD)"
printf 'x\n' > "$wu/x.txt" && git -C "$wu" add x.txt && git -C "$wu" commit -qm x && git -C "$wu" push -q -u origin "$bu" 2>/dev/null
"$P/scripts/steward.sh" release "$up" > /dev/null 2> "$work/split.err"
check "release: a branch merged into its upstream but ahead of the base is kept" sh -c "git show-ref --verify --quiet 'refs/heads/$bu' && grep -q 'is not merged into origin/main; kept' '$work/split.err'"
check "new: an unreadable parent is warned about, and the child is still made" sh -c "'$P/scripts/new.sh' task 'Orphan' --size S --parent local:task/999 --body x 2>'$work/split.err' | grep -q '^local:task/' && grep -q 'cannot read the parent local:task/999' '$work/split.err'"
unset FLOW_HEALTH_PROCS

[ "$fails" -eq 0 ] && { echo "decomposition: ok"; exit 0; }
echo "decomposition: $fails failed"; exit 1
