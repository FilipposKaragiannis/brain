#!/bin/sh
# epic-gates.sh: what waits on an epic's gates, on the local adapter in throwaway repos. A child
# no step has started is not ready, and a run that names it starts nothing, while its parent
# waits at the decomposition gate; it is ready once the gate clears, and a child already started
# goes on. An epic's closeout starts nothing while a child is open. A gate a step asked for by
# itself is not raised again by the profile once the owner answered it; it is raised when the
# owner sent the step back, and when the step never asked.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

# step_result <item> <step> <json>: writes the result file of the item's run in flight.
step_result() { printf '%s\n' "$3" > "$(json_value reports < "$(run_file "$1")")/$2.json"; }
# start_step <item>: next.sh on the named item; its exit code is the function's.
start_step() { "$plugin/scripts/next.sh" "$1" >/dev/null 2>&1; }
finish_step() { "$plugin/scripts/advance.sh" "$1" >/dev/null 2>&1; }

echo "epic gates: a child waits while its parent's split is not approved"
new_repo children
epic="$("$local_adapter/create.sh" epic "Physics" --body x)"
remote_branch "$(epic_of "$epic")"
child="$(new_task "Ball spin" "$epic")"
started_child="$(new_task "Ball drag" "$epic")"
start_step "$started_child"
"$plugin/scripts/gate.sh" raise "$epic" decomposition "Approve the split." >/dev/null 2>&1
check "ChildOfAParentAtTheDecompositionGate_IsNotReady: the pick must not start work on a split the owner has not approved" \
  '! ready_ids | grep -q -- "$child"'
check "ChildOfAParentAtTheDecompositionGate_IsNotReadyInAListOfTasksOnly: the parent is read through its adapter when the filter leaves it out of the list" \
  '! ready_ids --kind task | grep -q -- "$child"'
start_step "$child"; named_code=$?
check "NamedRunOfAChildBehindTheDecompositionGate_StartsNothing: exit 4 and no run record, as for any item that waits" \
  '[ "$named_code" -eq 4 ] && [ ! -f "$(run_file "$child")" ]'
check "ChildAlreadyStarted_KeepsItsRun: the owner let it start, so the parent gate does not take its run away" \
  '[ -f "$(run_file "$started_child")" ]'
"$plugin/scripts/gate.sh" clear "$epic" "Approved." >/dev/null 2>&1
check "ChildAfterTheDecompositionGateClears_IsReady: the owner approved the split" 'ready_ids | grep -q -- "$child"'

echo "epic gates: closeout waits for the children"
new_repo closeout
closing_epic="$("$local_adapter/create.sh" epic "Rendering" --body x)"
open_child="$(new_task "Sprite batch" "$closing_epic")"
"$local_adapter/write-state.sh" "$closing_epic" step=closeout profile=epic
start_step "$closing_epic"; closeout_code=$?
check "CloseoutWithAnOpenChild_StartsNothing: exit 4 and no run record, because closeout checks that every child is closed" \
  '[ "$closeout_code" -eq 4 ] && [ ! -f "$(run_file "$closing_epic")" ]'
"$local_adapter/close.sh" "$open_child" >/dev/null 2>&1
start_step "$closing_epic"; closed_code=$?
check "CloseoutWithEveryChildClosed_Starts: the run is recorded once nothing is open" \
  '[ "$closed_code" -eq 0 ] && [ -f "$(run_file "$closing_epic")" ]'

echo "epic gates: a gate the step asked for is not asked twice"
new_repo asked
asking_epic="$("$local_adapter/create.sh" epic "Audio" --body x)"
"$local_adapter/write-state.sh" "$asking_epic" step=tasks profile=epic
start_step "$asking_epic"
step_result "$asking_epic" tasks '{"status":"gate","gate":"decomposition","message":"**Approve these two slices?**"}'
finish_step "$asking_epic"
"$plugin/scripts/gate.sh" clear "$asking_epic" "Approved." >/dev/null 2>&1
start_step "$asking_epic"
step_result "$asking_epic" tasks '{"status":"done","summary":"two tasks created"}'
finish_step "$asking_epic"; answered_code=$?
check "StepThatAskedItsProfileGateAndWasAnswered_MovesOn: no gate after the step, because the owner already approved this split" \
  '[ "$answered_code" -eq 0 ] && [ "$(state "$asking_epic" gate)" = none ] && [ "$(state "$asking_epic" step)" = closeout ]'

sent_back_epic="$("$local_adapter/create.sh" epic "Input" --body x)"
"$local_adapter/write-state.sh" "$sent_back_epic" step=tasks profile=epic
start_step "$sent_back_epic"
step_result "$sent_back_epic" tasks '{"status":"gate","gate":"decomposition","message":"**Approve these two slices?**"}'
finish_step "$sent_back_epic"
"$plugin/scripts/gate.sh" clear "$sent_back_epic" --back "Split the second slice." >/dev/null 2>&1
start_step "$sent_back_epic"
step_result "$sent_back_epic" tasks '{"status":"done","summary":"three tasks created"}'
finish_step "$sent_back_epic"
check "StepSentBackAtItsOwnGate_IsAskedAgain: the owner never approved the reworked split, so the profile gate is raised" \
  '[ "$(state "$sent_back_epic" gate)" = decomposition ]'

silent_epic="$("$local_adapter/create.sh" epic "Netcode" --body x)"
"$local_adapter/write-state.sh" "$silent_epic" step=tasks profile=epic
start_step "$silent_epic"
step_result "$silent_epic" tasks '{"status":"done","summary":"two tasks created"}'
finish_step "$silent_epic"
check "StepThatNeverAsked_GetsTheProfileGate: nobody approved the split, so the gate is raised" \
  '[ "$(state "$silent_epic" gate)" = decomposition ]'

# remote_tip <branch>: the commit the remote holds the branch at, or nothing when it has none.
remote_tip() { git -C "$root/origin.git" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
# ask_for_the_split <epic>: the epic's tasks step ran and asks its decomposition gate.
ask_for_the_split() {
  "$local_adapter/write-state.sh" "$1" step=tasks profile=epic
  start_step "$1"
  step_result "$1" tasks '{"status":"gate","gate":"decomposition","message":"**Approve these slices?**"}'
  finish_step "$1"
}
health_pass() { "$plugin/scripts/steward.sh" health "$@" 2>&1; }

echo "epic gates: an approved split gives the epic its branch"
new_repo approved
approved_epic="$("$local_adapter/create.sh" epic "Replays" --body x)"
approved_child="$(new_task "Replay file" "$approved_epic")"
ask_for_the_split "$approved_epic"
check "EpicWaitingForItsSplitApproval_HasNoEpicBranch: nothing makes the branch before the owner approves, or the checks below prove nothing" \
  '[ -z "$(remote_tip "$(epic_of "$approved_epic")")" ]'
"$plugin/scripts/gate.sh" clear "$approved_epic" "Approved." >/dev/null 2>&1
check "ApprovedSplit_PutsTheEpicBranchOnTheRemoteAtTheConfigBase: the children of the epic start where the default branch stands" \
  '[ -n "$(remote_tip main)" ] && [ "$(remote_tip "$(epic_of "$approved_epic")")" = "$(remote_tip main)" ]'
check "ApprovedSplit_ChildIsReadyWithNoBranchPushedByHand: the approval is all the owner does" \
  'ready_ids | grep -qxF -- "$approved_child"'
start_step "$approved_child"
check "ApprovedSplit_ChildStartsFromTheEpicBranch: its PR merges into the epic, not into the default branch" \
  '[ "$(claim_base "$approved_child")" = "$(epic_of "$approved_epic")" ]'

sent_back="$("$local_adapter/create.sh" epic "Leagues" --body x)"
new_task "League table" "$sent_back" >/dev/null
ask_for_the_split "$sent_back"
"$plugin/scripts/gate.sh" clear "$sent_back" --back "Split the table from the fixtures." >/dev/null 2>&1
check "SplitSentBack_MakesNoEpicBranch: the owner did not approve this split" \
  '[ -z "$(remote_tip "$(epic_of "$sent_back")")" ]'

kept="$("$local_adapter/create.sh" epic "Awards" --body x)"
new_task "Award list" "$kept" >/dev/null
remote_branch "$(epic_of "$kept")"; remote_commit "$(epic_of "$kept")" awards.txt
kept_tip="$(remote_tip "$(epic_of "$kept")")"
ask_for_the_split "$kept"
"$plugin/scripts/gate.sh" clear "$kept" "Approved." >/dev/null 2>&1
check "ApprovedSplitOfAnEpicThatHasItsBranch_LeavesTheBranchWhereItIs: work already on the epic branch is never moved" \
  '[ -n "$kept_tip" ] && [ "$(remote_tip "$(epic_of "$kept")")" = "$kept_tip" ]'

outer="$("$local_adapter/create.sh" epic "Season" --body x)"
remote_branch "$(epic_of "$outer")"; remote_commit "$(epic_of "$outer")" season.txt
inner="$("$local_adapter/create.sh" epic "Playoffs" --body x --parent "$outer")"
new_task "Bracket" "$inner" >/dev/null
ask_for_the_split "$inner"
"$plugin/scripts/gate.sh" clear "$inner" "Approved." >/dev/null 2>&1
check "ApprovedSplitOfAnEpicUnderAnEpicWithABranch_StartsFromThatBranch: the inner epic builds on the outer epic's work" \
  '[ -n "$(remote_tip "$(epic_of "$outer")")" ] && [ "$(remote_tip "$(epic_of "$inner")")" = "$(remote_tip "$(epic_of "$outer")")" ]'

echo "epic gates: a branch the remote refuses leaves the gate cleared and the children waiting"
new_repo refused
printf '#!/bin/sh\nexit 1\n' > "$root/origin.git/hooks/pre-receive"; chmod +x "$root/origin.git/hooks/pre-receive"
refused_epic="$("$local_adapter/create.sh" epic "Trades" --body x)"
refused_child="$(new_task "Trade window" "$refused_epic")"
ask_for_the_split "$refused_epic"
"$plugin/scripts/gate.sh" clear "$refused_epic" "Approved." > "$work/refused.out" 2>&1
check "ApprovedSplitWhoseBranchTheRemoteRefuses_StillClearsTheGate: the owner's answer stands whatever git said" \
  '[ "$(state "$refused_epic" gate)" = none ]'
check "ApprovedSplitWhoseBranchTheRemoteRefuses_SaysTheChildrenWait: the owner hears why nothing starts" \
  'grep -qF "its children wait" "$work/refused.out"'
check "ApprovedSplitWhoseBranchTheRemoteRefuses_KeepsTheChildOutOfTheReadyList: no child starts on the default branch instead" \
  '! ready_ids | grep -qxF -- "$refused_child"'
check "ApprovedSplitWhoseBranchTheRemoteRefuses_KeepsItsTasksStep: the step that asked the gate has not run again, so only the owner's answer says the split is approved" \
  '[ "$(state "$refused_epic" step)" = tasks ]'
rm "$root/origin.git/hooks/pre-receive"
health_pass > "$work/health-retry.out"
check "ApprovedSplitWhoseBranchTheRemoteRefused_GetsItFromTheHealthJobOnceTheRemoteTakesIt: the approval stands, so the health job makes the branch without another run of the tasks step" \
  '[ -n "$(remote_tip main)" ] && [ "$(remote_tip "$(epic_of "$refused_epic")")" = "$(remote_tip main)" ]'

echo "epic gates: the health job gives an approved epic the branch it lacks"
new_repo backfill
older_epic="$("$local_adapter/create.sh" epic "Stadiums" --body x)"
older_child="$(new_task "Stadium list" "$older_epic")"
"$local_adapter/write-state.sh" "$older_epic" step=closeout profile=epic
hand_made="$("$local_adapter/create.sh" epic "Kits" --body x)"
new_task "Kit colours" "$hand_made" >/dev/null
waiting_epic="$("$local_adapter/create.sh" epic "Sponsors" --body x)"
new_task "Sponsor list" "$waiting_epic" >/dev/null
ask_for_the_split "$waiting_epic"
unreached="$("$local_adapter/create.sh" epic "Tickets" --body x)"
new_task "Ticket price" "$unreached" >/dev/null
"$local_adapter/write-state.sh" "$unreached" step=tasks profile=epic
health_pass --dry-run > "$work/health-dry.out"
check "HealthDryRun_MakesNoEpicBranch: a dry run only says what it would do" \
  '[ -z "$(remote_tip "$(epic_of "$older_epic")")" ] && grep -qF "would make its epic branch $(epic_of "$older_epic")" "$work/health-dry.out"'
health_pass > "$work/health.out"
check "EpicApprovedBeforeTheFlowMadeBranches_GetsItsBranchFromTheHealthJob: an upgrade must not leave its children waiting on the owner" \
  '[ -n "$(remote_tip main)" ] && [ "$(remote_tip "$(epic_of "$older_epic")")" = "$(remote_tip main)" ]'
check "EpicApprovedBeforeTheFlowMadeBranches_ChildIsReadyAfterTheHealthJob: the wait ends without a push by hand" \
  'ready_ids | grep -qxF -- "$older_child"'
check "EpicWhoseChildrenTheOwnerMadeByHand_GetsItsBranchFromTheHealthJob: the owner made the split, so nobody is left to approve it" \
  '[ -n "$(remote_tip "$(epic_of "$hand_made")")" ]'
check "EpicWaitingAtItsDecompositionGate_GetsNoBranchFromTheHealthJob: its split is not approved yet" \
  '[ -z "$(remote_tip "$(epic_of "$waiting_epic")")" ]'
check "EpicWhoseStepsHaveNotReachedTheGate_GetsNoBranchFromTheHealthJob: its split is still being made" \
  '[ -z "$(remote_tip "$(epic_of "$unreached")")" ]'

echo "epic gates: with no remote, the epic branch is made as a local one"
new_repo offline
git remote remove origin
offline_epic="$("$local_adapter/create.sh" epic "Friendlies" --body x)"
new_task "Friendly list" "$offline_epic" >/dev/null
ask_for_the_split "$offline_epic"
"$plugin/scripts/gate.sh" clear "$offline_epic" "Approved." >/dev/null 2>&1
check "ApprovedSplitInARepositoryWithNoRemote_MakesALocalEpicBranchAtTheConfigBase: the claim reads the epic branch among the local ones there" \
  '[ "$(git rev-parse -q --verify "refs/heads/$(epic_of "$offline_epic")")" = "$(git rev-parse main)" ]'

if [ "$fails" -eq 0 ]; then echo "epic-gates: ok"; else echo "epic-gates: $fails failed"; exit 1; fi
