#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh sets plugin, work, local_adapter and fails; the checks' conditions read the names set here
# epic-pr-claim.sh: a claim for an epic on its own epic branch, the worktree a comments pass on
# the epic's PR works in, on the local adapter in throwaway repos with a bare origin.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

echo "epic PR claim: an epic claimed on its epic branch while a pool worktree is free"
new_repo free_pool
epic="$("$local_adapter/create.sh" epic "Drills" --size L --body x)"
epic_branch="$(epic_of "$epic")"
remote_branch "$epic_branch"; remote_commit "$epic_branch" drills.txt
epic_worktree="$("$plugin/scripts/steward.sh" claim "$epic" --branch "$epic_branch" 2>/dev/null)"
check "EpicClaimedOnItsEpicBranchWithAFreePool_WorktreeStandsAtTheRemoteEpicTip: the pass commits and pushes on the epic PR's branch, so the worktree must hold the epic's own history, not a new branch of that name cut from the base" \
  '[ "$(git -C "$epic_worktree" rev-parse HEAD)" = "$(remote_tip "$epic_branch")" ]'

echo "epic PR claim: an epic claimed on its epic branch while the local branch lags the remote"
new_repo stale_local_branch
epic="$("$local_adapter/create.sh" epic "Drills" --size L --body x)"
epic_branch="$(epic_of "$epic")"
remote_branch "$epic_branch"; git fetch -q origin && git branch -q "$epic_branch" "origin/$epic_branch"
remote_commit "$epic_branch" drills.txt
epic_worktree="$("$plugin/scripts/steward.sh" claim "$epic" --branch "$epic_branch" 2>/dev/null)"
check "EpicClaimedOnItsEpicBranchBehindTheRemote_WorktreeStandsAtTheRemoteEpicTip: a closeout's release keeps the local epic branch while the PR's branch moves on, so the pass must work on the remote's commits, not on the older local tip" \
  '[ "$(git -C "$epic_worktree" rev-parse HEAD)" = "$(remote_tip "$epic_branch")" ]'

[ "$fails" -eq 0 ] && { echo "epic-pr-claim: ok"; exit 0; }
echo "epic-pr-claim: $fails failed"; exit 1
