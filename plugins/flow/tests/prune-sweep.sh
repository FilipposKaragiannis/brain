#!/bin/sh
# prune-sweep.sh: help, prune and sweep.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
echo "help"
check "help lists every skill" sh -c "for s in \$(ls '$P/skills'); do '$P/scripts/help.sh' | grep -q \"^| \$s |\" || exit 1; done"
check "help <skill> shows one" sh -c "'$P/scripts/help.sh' gate | grep -q '/flow:gate'"
check "help lines shows every profile" sh -c "'$P/scripts/help.sh' lines | grep -q 'task L' && '$P/scripts/help.sh' lines | grep -q '\[plan-approval\]'"
check "help gates names every gate" sh -c "for g in interview plan-approval decomposition feel-test merge escalation ambiguity; do '$P/scripts/help.sh' gates | grep -q \"\*\*\$g\*\*\" || exit 1; done"
check "help of an unknown skill fails" sh -c "! '$P/scripts/help.sh' nonesuch >/dev/null"
cd "$repo"

echo "prune"
pc="$("$P/adapters/local/create.sh" task "Pruned")"; "$P/adapters/local/close.sh" "$pc" >/dev/null
po="$("$P/adapters/local/create.sh" task "Still open")"
pk="$("$P/adapters/local/create.sh" task "Closed but claimed")"; wk="$("$P/scripts/steward.sh" claim "$pk")"; "$P/adapters/local/close.sh" "$pk" >/dev/null
for d in "$repo" "$(cd ../wt-1 && pwd)"; do mkdir -p "$d/.flow/reports/$(item_slug "$pc")" "$d/.flow/reports/$(item_slug "$po")" "$d/.flow/reports/298"; done
mkdir -p "$wk/.flow/reports/$(item_slug "$pk")"
out="$("$P/scripts/steward.sh" prune --dry-run 2>&1)"
check "prune: --dry-run names the closed item's folders and deletes nothing" sh -c "[ \"\$(printf '%s' '$out' | grep -c 'would remove .*/$(item_slug "$pc") ')\" = 2 ] && [ -d '$repo/.flow/reports/$(item_slug "$pc")' ]"
out="$("$P/scripts/steward.sh" prune 2>&1)"
check "prune: removes a closed item's reports in the main and pool worktrees" sh -c "[ ! -e '$repo/.flow/reports/$(item_slug "$pc")' ] && [ ! -e '../wt-1/.flow/reports/$(item_slug "$pc")' ]"
check "prune: keeps an open item's reports" [ -d "$repo/.flow/reports/$(item_slug "$po")" ]
check "prune: keeps a claimed item's reports even when closed" [ -d "$wk/.flow/reports/$(item_slug "$pk")" ]
check "prune: keeps and names a folder that is not an item's" sh -c "[ -d '$repo/.flow/reports/298' ] && printf '%s' '$out' | grep -q 'reports/298: not an item folder'"
check "reports: a claimed item's folder is in its worktree" [ "$("$P/scripts/steward.sh" reports "$pk")" = "$wk/.flow/reports/$(item_slug "$pk")" ]
check "reports: an unclaimed item's existing folder is found in the pool" [ "$("$P/scripts/steward.sh" reports "$po")" = "$(cd ../wt-1 && pwd -P)/.flow/reports/$(item_slug "$po")" ]
pn="$("$P/adapters/local/create.sh" task "No reports yet")"
check "reports: a new item's folder is made in the main worktree" sh -c "[ \"\$('$P/scripts/steward.sh' reports '$pn')\" = '$(cd "$repo" && pwd -P)/.flow/reports/$(item_slug "$pn")' ] && [ -d '$repo/.flow/reports/$(item_slug "$pn")' ]"
"$P/scripts/steward.sh" reports 298 >/dev/null 2>&1; code=$?
check "reports: a bare number is not an item id (exit 2)" [ "$code" -eq 2 ]
check "release: a closed item's reports go with it" sh -c "'$P/scripts/steward.sh' release '$pk' --force && [ ! -e '$wk/.flow/reports/$(item_slug "$pk")' ]"
"$P/scripts/steward.sh" claim "$po" >/dev/null 2>&1; wo="$("$P/scripts/steward.sh" find "$po")"
check "release: an open item's reports stay" sh -c "'$P/scripts/steward.sh' release '$po' --force && [ -d '$repo/.flow/reports/$(item_slug "$po")' ]"

echo "sweep"
# The fake gh answers pr view with the PR in its state file, whatever the URL. One pool
# worktree is free here, so each case claims it in turn.
fake_pr() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pr"]={"number":90,"state":sys.argv[2],"isDraft":False,"mergedAt":None,"url":"https://gh/pull/90","headRefName":sys.argv[4],"headRefOid":sys.argv[3],"baseRefName":"main"}; json.dump(d,open(p,"w"))' "$FAKE_GH_DIR/issues.json" "$1" "$2" "${3:-}"; }
. "$here/_claimed_worktree_fixture.sh"
idle_open="$("$P/adapters/local/create.sh" task "Open, claimed, nothing to sweep")"; "$P/scripts/steward.sh" claim "$idle_open" >/dev/null
sc="$("$P/adapters/local/create.sh" task "Closed, claimed")"; wc_="$("$P/scripts/steward.sh" claim "$sc")"
"$P/adapters/local/close.sh" "$sc" >/dev/null
check "sweep --dry-run: names the closed item's worktree and touches nothing" sh -c "'$P/scripts/steward.sh' sweep --dry-run | grep -q '$sc: would release' && [ -f '$wc_/.flow/claim.json' ]"
printf 'x\n' > "$wc_/dirty.txt"
check "sweep: uncommitted changes keep the worktree" sh -c "'$P/scripts/steward.sh' sweep | grep -q '$sc: kept .*uncommitted' && [ -f '$wc_/.flow/claim.json' ]"
rm "$wc_/dirty.txt"
check "sweep: a closed item's worktree is released" sh -c "'$P/scripts/steward.sh' sweep | grep -q '$sc: released' && [ ! -f '$wc_/.flow/claim.json' ]"
sm="$("$P/adapters/local/create.sh" task "Merged PR")"; wm="$("$P/scripts/steward.sh" claim "$sm")"
tip="$(commit_in "$wm" merged)"; "$P/adapters/local/link-pr.sh" "$sm" https://gh/pull/90
"$P/scripts/gate.sh" raise "$sm" merge "Merge the PR." >/dev/null 2>&1
fake_pr OPEN "$tip"
check "sweep: an open PR keeps its worktree" sh -c "[ -z \"\$('$P/scripts/steward.sh' sweep)\" ] && [ -f '$wm/.flow/claim.json' ]"
fake_pr MERGED "$tip"
out="$("$P/scripts/steward.sh" sweep)"
check "sweep: a merged PR releases its worktree" sh -c "printf '%s' '$out' | grep -q '$sm: released .*pull/90 merged' && [ ! -f '$wm/.flow/claim.json' ]"
check "sweep: the merge gate clears with the PR" sh -c "[ \"\$('$P/adapters/local/read.sh' '$sm' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"gate\"])')\" = none ] && [ ! -f .flow/gates/$(item_slug "$sm").json ] && grep -q 'Gate cleared: merged: https://gh/pull/90' .flow/items/task/${sm##*/}.md"
check "sweep: the item closes when the merge did not close it" [ "$("$P/adapters/local/read.sh" "$sm" | jget status)" = closed ]
check "sweep: a squash-merged branch at the PR's head is deleted" sh -c "! git -C '$wm' show-ref --verify --quiet refs/heads/flow/$(item_slug "$sm")"
# A PR merged while a gate other than merge was open: the sweep closes the item, and the gate
# goes with it.
ambiguity_item="$("$P/adapters/local/create.sh" task "Merged with an ambiguity gate open")"; ambiguity_worktree="$("$P/scripts/steward.sh" claim "$ambiguity_item")"
"$P/adapters/local/link-pr.sh" "$ambiguity_item" https://gh/pull/90
"$P/scripts/gate.sh" raise "$ambiguity_item" ambiguity "Which row owns the retune?" >/dev/null 2>&1
check_all "GateList_OpenAmbiguityGate_NamesTheItem: gate.sh list names the gate before the sweep" 'gates="$("$P/scripts/gate.sh" list)" && printf "%s\n" "$gates" | grep -q "	$ambiguity_item	"'
fake_pr MERGED "$(commit_in "$ambiguity_worktree" ambiguous)"
"$P/scripts/steward.sh" sweep >/dev/null 2>&1
check "Sweep_MergedItemWithOpenGate_LeavesNoGate: gate.sh list names no gate of an item the sweep closed" sh -c "gates=\"\$('$P/scripts/gate.sh' list)\" && ! printf '%s\\n' \"\$gates\" | grep -q '	$ambiguity_item	'"
escalation_item="$("$P/adapters/local/create.sh" task "Merged with an escalation gate open")"; escalation_worktree="$("$P/scripts/steward.sh" claim "$escalation_item")"
"$P/adapters/local/link-pr.sh" "$escalation_item" https://gh/pull/90
escalation_question="Which atlas row keeps the NetFriction retune?"
"$P/scripts/gate.sh" raise "$escalation_item" escalation "$escalation_question" >/dev/null 2>&1
fake_pr MERGED "$(commit_in "$escalation_worktree" escalated)"
"$P/scripts/steward.sh" sweep > "$work/sweep-unanswered.out" 2>/dev/null
check_all "Sweep_UnansweredEscalationGate_ReportNamesItUnanswered: the sweep's output marks the item's gate unanswered" 'grep "^$escalation_item: " "$work/sweep-unanswered.out" | grep -qi unanswered'
check "Sweep_UnansweredEscalationGate_ReportQuotesTheQuestion: the sweep's output quotes the question nobody answered" grep -qF "$escalation_question" "$work/sweep-unanswered.out"
check "Sweep_UnansweredEscalationGate_QuotedOnTheItem: a comment on the closed item marks the question unanswered and quotes it" sh -c "sed -n '/[Uu]nanswered/,\$p' .flow/items/task/${escalation_item##*/}.md | grep -qF '$escalation_question'"
feel_item="$("$P/adapters/github/create.sh" task "Merged with a feel-test gate open")"; feel_worktree="$("$P/scripts/steward.sh" claim "$feel_item")"
"$P/adapters/github/link-pr.sh" "$feel_item" https://gh/pull/90
"$P/scripts/gate.sh" raise "$feel_item" feel-test "Launch it and play a match." >/dev/null 2>&1
issue_labels() { python3 -c 'import json,sys; print("\n".join(next(i for i in json.load(open(sys.argv[1]))["issues"] if i["number"] == int(sys.argv[2]))["labels"]))' "$FAKE_GH_DIR/issues.json" "${1#gh#}"; }
check_all "GateRaise_GitHubItem_CarriesTheGateLabel: a gate raised on a GitHub item labels the issue" 'issue_labels "$feel_item" | grep -qx gate:feel-test'
fake_pr MERGED "$(commit_in "$feel_worktree" felt)"
"$P/scripts/steward.sh" sweep > "$work/sweep-feel.out" 2>/dev/null
check "Sweep_MergedGitHubItem_ClosesTheIssue: the sweep closes the merged GitHub item" [ "$("$P/adapters/github/read.sh" "$feel_item" | jget status)" = closed ]
check_all "Sweep_MergedGitHubItemWithOpenGate_RemovesTheGateLabel: the issue the sweep closed keeps no gate: label" 'labels="$(issue_labels "$feel_item")" && ! printf "%s\n" "$labels" | grep -q "^gate:"'
check_all "Sweep_FeelTestGate_ReportNamesTheDrop: the sweep's output names the item's feel-test gate" 'grep -q "^$feel_item: .*feel-test" "$work/sweep-feel.out"'
check_all "Sweep_FeelTestGate_NotReportedUnanswered: a feel-test gate asks no question, so the sweep carries none forward" 'grep -q "^$feel_item: " "$work/sweep-feel.out" && ! grep "^$feel_item: " "$work/sweep-feel.out" | grep -qi unanswered'
issue_item="$("$P/adapters/github/create.sh" task "Merged with an ambiguity gate open")"; issue_worktree="$("$P/scripts/steward.sh" claim "$issue_item")"
"$P/adapters/github/link-pr.sh" "$issue_item" https://gh/pull/90
ambiguous_question="Does 05-settings-catalog.md:102 still own the NetFriction retune?"
"$P/scripts/gate.sh" raise "$issue_item" ambiguity "$ambiguous_question" >/dev/null 2>&1
fake_pr MERGED "$(commit_in "$issue_worktree" asked)"
"$P/scripts/steward.sh" sweep >/dev/null 2>&1
issue_quotes_unanswered() { python3 -c 'import json,sys; comments=next(i for i in json.load(open(sys.argv[1]))["issues"] if i["number"] == int(sys.argv[2])).get("comments", [])
sys.exit(0 if any(sys.argv[3] in c["body"] and "unanswered" in c["body"].lower() for c in comments) else 1)' "$FAKE_GH_DIR/issues.json" "${1#gh#}" "$2"; }
check "Sweep_UnansweredAmbiguityGate_QuotedUnansweredOnTheClosedIssue: a comment on the closed GitHub issue quotes the question and marks it unanswered" issue_quotes_unanswered "$issue_item" "$ambiguous_question"
sl="$("$P/adapters/local/create.sh" task "Commit after merge")"; wl="$("$P/scripts/steward.sh" claim "$sl")"
merged_tip="$(commit_in "$wl" first)"; commit_in "$wl" later >/dev/null
"$P/adapters/local/link-pr.sh" "$sl" https://gh/pull/90; fake_pr MERGED "$merged_tip"
"$P/scripts/steward.sh" sweep >/dev/null 2>&1
check "sweep: a commit after the merge keeps the branch" sh -c "[ ! -f '$wl/.flow/claim.json' ] && git -C '$wl' show-ref --verify --quiet refs/heads/flow/$(item_slug "$sl")"
# A gate the sweep cannot take off (the tracker write fails; a read-only item file here) keeps the
# claim, so the next sweep, which reads only claimed worktrees, tries again.
for kept_gate in ambiguity merge; do
  kept_item="$("$P/adapters/local/create.sh" task "Merged, its $kept_gate gate cannot go")"; kept_worktree="$("$P/scripts/steward.sh" claim "$kept_item")"
  "$P/adapters/local/link-pr.sh" "$kept_item" https://gh/pull/90
  "$P/scripts/gate.sh" raise "$kept_item" "$kept_gate" "Which row owns the retune?" >/dev/null 2>&1
  fake_pr MERGED "$(commit_in "$kept_worktree" "kept-$kept_gate")"
  kept_file=".flow/items/task/${kept_item##*/}.md"; chmod a-w "$kept_file"
  "$P/scripts/steward.sh" sweep > "$work/sweep-kept.out" 2>/dev/null
  chmod u+w "$kept_file"
  check_all "Sweep_${kept_gate}GateDropFails_KeepsTheClaim: the sweep keeps the worktree of an item whose gate stays, so the next sweep can retry" '[ -f "$kept_worktree/.flow/claim.json" ] && grep -q "^$kept_item: kept .*could not drop its $kept_gate gate.*the next sweep tries again" "$work/sweep-kept.out" && ! grep -q "^$kept_item: released" "$work/sweep-kept.out"'
  check_all "Sweep_${kept_gate}GateDropFails_LeavesTheItemOpenAndGated: the item the sweep could not ungate stays open, its gate listed" '[ "$("$P/adapters/local/read.sh" "$kept_item" | jget status)" != closed ] && "$P/scripts/gate.sh" list | grep -q "	$kept_item	$kept_gate	"'
  "$P/scripts/steward.sh" sweep > "$work/sweep-kept.out" 2>/dev/null
  check_all "Sweep_${kept_gate}GateDropRetried_ReleasesAndCloses: the next sweep takes the gate off, closes the item and releases its worktree" 'grep -q "^$kept_item: released" "$work/sweep-kept.out" && [ ! -f "$kept_worktree/.flow/claim.json" ] && [ "$("$P/adapters/local/read.sh" "$kept_item" | jget status)" = closed ] && ! "$P/scripts/gate.sh" list | grep -q "	$kept_item	"'
done
# A pr step whose worker cannot write the local item file (it lies outside the worker's sandbox)
# leaves the PR unrecorded: advance records the URL the step's result names, and the sweep finds
# by the item's task branch a PR nobody recorded, one advance's own lookup could not read.
ap="$("$P/adapters/local/create.sh" task "PR its worker could not link" --size S)"; "$P/adapters/local/write-state.sh" "$ap" step=pr
printf '{"status":"done","summary":"PR open","pr":"https://gh/pull/90"}\n' > "$("$P/scripts/next.sh" "$ap" --json | jget reports)/pr.json"
"$P/scripts/advance.sh" "$ap" >/dev/null 2>&1
check "advance: a pr step's result records its PR on an item link-pr never reached" [ "$("$P/adapters/local/read.sh" "$ap" | jget state.pr)" = https://gh/pull/90 ]
"$P/scripts/gate.sh" clear "$ap" merged >/dev/null; "$P/scripts/steward.sh" release "$ap" --force >/dev/null 2>&1; "$P/adapters/local/close.sh" "$ap" >/dev/null
sp="$("$P/adapters/local/create.sh" task "PR found by its branch" --size S)"; "$P/adapters/local/write-state.sh" "$sp" step=pr
printf '{"status":"done","summary":"PR open"}\n' > "$("$P/scripts/next.sh" "$sp" --json | jget reports)/pr.json"
fake_pr OPEN "$(commit_in "$("$P/scripts/steward.sh" find "$sp")" found-by-branch)" "flow/$(item_slug "$sp")"
printf '1\ngh: HTTP 401: Bad credentials\npr list\n' > "$FAKE_GH_DIR/fail"
"$P/scripts/advance.sh" "$sp" >/dev/null 2>&1
rm -f "$FAKE_GH_DIR/fail"
fake_pr MERGED "$(git -C "$("$P/scripts/steward.sh" find "$sp")" rev-parse HEAD)" "flow/$(item_slug "$sp")"
"$P/scripts/steward.sh" sweep >/dev/null 2>&1
check "sweep: an item at the merge gate with no PR recorded finds it by its branch, and the merge gate clears" [ "$("$P/adapters/local/read.sh" "$sp" | jget state.gate)" = none ]
check "sweep: the PR found by the branch is recorded on the item" [ "$("$P/adapters/local/read.sh" "$sp" | jget state.pr)" = https://gh/pull/90 ]
# The console sweeps one item once its gated PR leaves the open list; a sweep already running is enough.
si="$("$P/adapters/local/create.sh" task "Swept alone")"; wi="$("$P/scripts/steward.sh" claim "$si")"
"$P/adapters/local/close.sh" "$si" >/dev/null
sleep 30 & held=$!
mkdir -p .flow/sweep.lock && echo "$held" > .flow/sweep.lock/pid
"$P/scripts/steward.sh" sweep --lock --item "$si" > "$work/sweep.out" 2>&1; code=$?
check_all "sweep --lock: a held sweep lock exits 75 at once, says so, and keeps the worktree" '[ "$code" -eq 75 ] && grep -q "sweep skipped: the sweep lock is held" "$work/sweep.out" && [ -f "$wi/.flow/claim.json" ]'
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null; rm -rf .flow/sweep.lock
check "sweep --item: another item's worktree is not looked at" sh -c "out=\"\$('$P/scripts/steward.sh' sweep --item local:task/999)\" && [ -z \"\$out\" ] && [ -f '$wi/.flow/claim.json' ]"
check "sweep --lock --item: the item's worktree is released and the lock is let go" sh -c "'$P/scripts/steward.sh' sweep --lock --item '$si' | grep -q '$si: released' && [ ! -f '$wi/.flow/claim.json' ] && [ ! -d .flow/sweep.lock ]"
merged_item="$("$P/adapters/local/create.sh" task "Merged PR, swept by the health job")"; merged_worktree="$("$P/scripts/steward.sh" claim "$merged_item")"
"$P/adapters/local/link-pr.sh" "$merged_item" https://gh/pull/90
"$P/scripts/gate.sh" raise "$merged_item" merge "Merge the PR." >/dev/null 2>&1
fake_pr MERGED "$(git -C "$merged_worktree" rev-parse HEAD)"
check "health job --dry-run: names the merged PR's worktree and keeps it" sh -c "'$P/jobs/health.sh' claude --dry-run | grep -q '$merged_item: would release' && [ -f '$merged_worktree/.flow/claim.json' ]"
sleep 30 & held=$!
mkdir -p .flow/sweep.lock && echo "$held" > .flow/sweep.lock/pid
FLOW_LOCK_WAIT=1 "$P/jobs/health.sh" claude >/dev/null 2>&1; code=$?
check_all "health job: a held sweep lock skips the sweep, says so, and the run still ends cleanly" '[ "$code" -eq 0 ] && [ -f "$merged_worktree/.flow/claim.json" ] && grep -q "sweep skipped: the sweep lock is held" .flow/log/health.log && [ ! -d .flow/log/health.lock ]'
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null; rm -rf .flow/sweep.lock
"$P/jobs/health.sh" claude >/dev/null 2>&1
check "health job: the sweep clears a merged PR's gate and frees its worktree" sh -c "[ ! -f '$merged_worktree/.flow/claim.json' ] && [ ! -f .flow/gates/$(item_slug "$merged_item").json ] && grep -q '$merged_item: released' .flow/log/health.log"
check "health job: a run that swept says done and what it released" sh -c "grep '\"job\":\"health\"' .flow/log/runs.jsonl | tail -1 | grep -q '\"result\":\"done' && tail -n 3 .flow/log/health.log | grep -q '$merged_item: released'"
fake_pr OPEN ""

[ "$fails" -eq 0 ] && { echo "prune-sweep: ok"; exit 0; }
echo "prune-sweep: $fails failed"; exit 1
