#!/bin/sh
# pr-without-pull-request.sh: how an item ends when its pr step opens no pull request, on the local
# adapter in a throwaway repo. A pr step done with no PR in its result and nothing on the task
# branch its base lacks leaves nothing for the owner to merge: the item closes and frees its
# worktree. With changes on the branch and no PR there it escalates, also when the claim or the
# record names the task branch as its base; with no base recorded the claim's base is compared. A
# release keeps a task branch its claim's base, read by its full ref, does not hold, and deletes
# one merged into it. With a PR on the branch it waits at the merge gate. The board lists a merge
# gate with no PR linked under Health.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

NO_PULL_REQUEST_SUMMARY="No PR opened: the change had nothing to commit. Close the item."
PULL_REQUEST_ON_THE_BRANCH="https://github.invalid/owner/app/pull/731"
# closing_comment <item>: the comment the local item file records with the time it was closed, or nothing.
closing_comment() { python3 -c 'import re,sys; text=open(sys.argv[1]).read(); closed=re.search(r"^closed: *\"?([^\"\s]+)", text, re.M)
if closed: print("\n".join(line for line in text.splitlines() if line.startswith("- %s: " % closed.group(1))))' "$(item_field "$1" url)"; }
item_field() { "$local_adapter/read.sh" "$1" | json_value "$2"; }
# start_step_with_a_commit <item> <file>: the pr step started, with one commit adding <file> on its task branch.
start_step_with_a_commit() {
  "$local_adapter/write-state.sh" "$1" step=pr profile=bugfix
  start_step "$1"
  task_worktree="$("$plugin/scripts/steward.sh" find "$1")"
  printf '%s\n' "$2" > "$task_worktree/$2"
  git -C "$task_worktree" add -- "$2" && git -C "$task_worktree" commit -qm "$2"
}
offline_gh="$(cat "$work/offline/gh")"
gh_offline() { printf '%s\n' "$offline_gh" > "$work/offline/gh"; }
gh_finds_a_pull_request_on_every_branch() {
  printf '#!/bin/sh\ncase "$1 $2" in "pr list") echo %s ;; esac\n' "'[{\"url\": \"$PULL_REQUEST_ON_THE_BRANCH\"}]'" > "$work/offline/gh"
}
gh_cannot_answer() { printf '#!/bin/sh\nexit 1\n' > "$work/offline/gh"; }
# board_section <title>: the lines of the board's section under the heading ## <title>.
board_section() { printf '%s\n' "$board_output" | awk -v heading="## $1" '$0 == heading { inside = 1; next } /^## / { inside = 0 } inside'; }
pass_pr_step_with_no_pull_request() {
  "$local_adapter/write-state.sh" "$1" step=pr profile=bugfix
  start_step "$1"
  step_result "$1" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
  finish_step "$1"
}

echo "pr without a pull request: nothing to merge raises no merge gate"
new_repo nothing-to-merge
sign_off="$("$local_adapter/create.sh" bug "Owner sign-off with no code" --size S --body "$body")"
pass_pr_step_with_no_pull_request "$sign_off"
check "PrStepWithNoPullRequestAndAnEmptyBranchDiff_RaisesNoMergeGate: there is no pull request to merge, so a merge gate would wait forever" \
  '[ "$(archived_state "$sign_off" gate)" = null ]'
check "PrStepWithNoPullRequestAndAnEmptyBranchDiff_ClosesTheItem: with nothing to merge the item is finished, so it must not stay open" \
  '[ "$(item_field "$sign_off" status)" = closed ]'
check "PrStepWithNoPullRequestAndAnEmptyBranchDiff_ClosesWithTheStepSummary: the closing comment tells the tracker why the item ended" \
  'closing_comment "$sign_off" | grep -qF "$NO_PULL_REQUEST_SUMMARY"'
check "PrStepWithNoPullRequestAndAnEmptyBranchDiff_ReleasesTheWorktree: a closed item must not hold a pool worktree" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$sign_off")" ]'

echo "pr without a pull request: a child of a claimed parent compares against the parent's local tip"
ahead_parent="$(new_task "Parent with unpushed work")"
ahead_parent_worktree="$("$plugin/scripts/steward.sh" claim "$ahead_parent" 2>/dev/null)"
git -C "$ahead_parent_worktree" push -q origin "flow/$(slug "$ahead_parent")"
printf 'unpushed\n' > "$ahead_parent_worktree/unpushed.txt" && git -C "$ahead_parent_worktree" add unpushed.txt && git -C "$ahead_parent_worktree" commit -qm unpushed
unchanged_child="$(new_task "Child with no change of its own" "$ahead_parent")"
pass_pr_step_with_no_pull_request "$unchanged_child"
check "ChildOfAClaimedParentWithUnpushedCommitsAndNoChange_ClosesTheItem: the parent's unpushed work is not the child's, so the child has nothing to merge" \
  '[ "$(item_field "$unchanged_child" status)" = closed ]'
check "ChildOfAClaimedParentWithUnpushedCommitsAndNoChange_RaisesNoEscalationGate: nothing to merge needs no owner" \
  '[ "$(archived_state "$unchanged_child" gate)" = null ]'

echo "pr without a pull request: changes on the branch with no PR there escalate"
unopened="$("$local_adapter/create.sh" bug "Change whose PR was never opened" --size S --body "$body")"
start_step_with_a_commit "$unopened" unopened-change
step_result "$unopened" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
finish_step "$unopened"
check "PrStepWithNoPullRequestAndChangesOnTheBranch_RaisesAnEscalationGate: a change nobody opened a PR for needs the owner, not a silent close" \
  '[ "$(state "$unopened" gate)" = escalation ]'
check "PrStepWithNoPullRequestAndChangesOnTheBranch_LeavesTheItemOpen: changes that never merged mean the item is not finished" \
  '[ "$(item_field "$unopened" status)" = open ]'

echo "pr without a pull request: a claim base rewritten to the task branch is not read as nothing to merge"
rewritten="$("$local_adapter/create.sh" bug "Change whose claim names its own branch as base" --size S --body "$body")"
start_step_with_a_commit "$rewritten" rewritten-change
rewritten_branch="$(state "$rewritten" branch)"
set_claim_base "$rewritten" "$rewritten_branch"
step_result "$rewritten" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
finish_step "$rewritten"
check "PrStepWithNoPullRequestAndTheClaimBaseOnTheTaskBranch_RaisesAnEscalationGate because the item's record, not the claim, names the base the change must reach" \
  '[ "$(state "$rewritten" gate)" = escalation ]'
check "PrStepWithNoPullRequestAndTheClaimBaseOnTheTaskBranch_LeavesTheItemOpen because changes that never merged mean the item is not finished" \
  '[ "$(item_field "$rewritten" status)" = open ]'
"$plugin/scripts/steward.sh" release "$rewritten" >/dev/null 2>&1
check "ReleaseWithTheClaimBaseOnTheTaskBranch_KeepsTheTaskBranch because a branch is never merged into itself, so its commits are not yet anywhere else" \
  'git show-ref --verify --quiet "refs/heads/$rewritten_branch"'

echo "pr without a pull request: a recorded base on the task branch is not read as nothing to merge"
recorded_on_branch="$("$local_adapter/create.sh" bug "Change whose record names its own branch as base" --size S --body "$body")"
start_step_with_a_commit "$recorded_on_branch" recorded-on-branch-change
"$plugin/scripts/state.sh" set "$recorded_on_branch" "base=$(state "$recorded_on_branch" branch)" >/dev/null
step_result "$recorded_on_branch" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
finish_step "$recorded_on_branch"
check "PrStepWithNoPullRequestAndTheRecordedBaseOnTheTaskBranch_RaisesAnEscalationGate because a branch compared with itself always shows nothing to merge" \
  '[ "$(state "$recorded_on_branch" gate)" = escalation ]'

echo "pr without a pull request: with no recorded base the claim's base is the one compared"
claim_only="$("$local_adapter/create.sh" bug "Change whose record holds no base" --size S --body "$body")"
start_step_with_a_commit "$claim_only" claim-only-change
git branch claim-only-base "$(state "$claim_only" branch)"
"$plugin/scripts/state.sh" set "$claim_only" base= >/dev/null
set_claim_base "$claim_only" claim-only-base
step_result "$claim_only" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
finish_step "$claim_only"
check "PrStepWithNoPullRequestAndNoRecordedBase_ComparesWithTheClaimsBase because an item whose record holds no base has only its claim to go by" \
  'closing_comment "$claim_only" | grep -qF "no change against claim-only-base"'

echo "release: the claim's base is read by its full ref"
short_ref_base="$("$local_adapter/create.sh" bug "Change whose claim names its branch by a short ref" --size S --body "$body")"
start_step_with_a_commit "$short_ref_base" short-ref-change
short_ref_branch="$(state "$short_ref_base" branch)"
set_claim_base "$short_ref_base" "heads/$short_ref_branch"
"$plugin/scripts/steward.sh" release "$short_ref_base" >/dev/null 2>&1
check "ReleaseWithTheClaimBaseNamingTheTaskBranchByAShortRef_KeepsTheTaskBranch because no base branch of that name holds the commits" \
  'git show-ref --verify --quiet "refs/heads/$short_ref_branch"'
merged="$("$local_adapter/create.sh" bug "Change merged into its base" --size S --body "$body")"
start_step_with_a_commit "$merged" merged-change
merged_branch="$(state "$merged" branch)"
git merge -q --ff-only "$merged_branch" && git push -q origin main
"$plugin/scripts/steward.sh" release "$merged" >/dev/null 2>&1
check "ReleaseOfABranchMergedIntoItsBase_DeletesTheTaskBranch because its base holds every commit of it" \
  '! git show-ref --verify --quiet "refs/heads/$merged_branch"'

echo "pr without a pull request in its result: a PR on the branch waits at the merge gate"
unrecorded="$("$local_adapter/create.sh" bug "Change whose PR its worker did not record" --size S --body "$body")"
start_step_with_a_commit "$unrecorded" unrecorded-change
step_result "$unrecorded" pr "{\"status\":\"done\",\"summary\":\"PR open\"}"
gh_finds_a_pull_request_on_every_branch
finish_step "$unrecorded"
gh_offline
check "PrStepWithAPullRequestOnlyOnTheBranch_RaisesTheMergeGate: a PR the worker did not record still has to merge, so the owner waits on it" \
  '[ "$(state "$unrecorded" gate)" = merge ]'

echo "pr without a pull request: a lookup gh cannot answer keeps changes at the merge gate"
unanswered="$("$local_adapter/create.sh" bug "Change whose PR lookup failed" --size S --body "$body")"
start_step_with_a_commit "$unanswered" unanswered-change
step_result "$unanswered" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
gh_cannot_answer
finish_step "$unanswered"
gh_offline
check "PrStepWithChangesAndAFailedPullRequestLookup_KeepsTheMergeGate: a PR gh could not see may exist, so the sweep looks again from the merge gate" \
  '[ "$(state "$unanswered" gate)" = merge ]'

echo "board: a merge gate with no PR linked is a Health line"
stranded="$("$local_adapter/create.sh" bug "Merge gate raised before any PR" --size S --body "$body")"
"$plugin/scripts/gate.sh" raise "$stranded" merge "Merge the pull request." pr >/dev/null 2>&1
board_output="$("$plugin/scripts/board.sh" 2>/dev/null)"
check "MergeGateWithNoLinkedPullRequest_IsNotListedAsWaitingOnYou: there is no PR for the owner to merge" \
  '! board_section "Waiting on you" | grep -qF "$stranded"'
check "MergeGateWithNoLinkedPullRequest_IsFlaggedUnderHealth: a gate nothing can clear must still be seen" \
  'board_section Health | grep -qF "$stranded"'
check "MergeGateWithALinkedPullRequest_IsListedAsWaitingOnYou: a PR to merge is the owner's to act on" \
  'board_section "Waiting on you" | grep -qF "$unrecorded"'

if [ "$fails" -eq 0 ]; then echo "pr-without-pull-request: ok"; else echo "pr-without-pull-request: $fails failed"; exit 1; fi
