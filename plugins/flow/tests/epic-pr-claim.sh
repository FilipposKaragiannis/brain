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

echo "epic PR claim: an epic claimed on its epic branch grows the pool with a worktree of its own"
new_repo grown_pool
for worktree_number in 1 2 3; do git worktree remove "../wt-$worktree_number" && git branch -q -D "main-wt-$worktree_number"; done
copied_file='local.env'; setup_mark='setup.txt'
printf 'adapters:\n  default: local\nbase: main\npool:\n  # - ../app-wt-1\npool_max: 8\nworktree_copy:\n  - %s\nworktree_setup:\n  - printf ran > %s\nnotify:\n  desktop: false\n' "$copied_file" "$setup_mark" > .flow/config.yaml
printf 'secret\n' > "$copied_file"
printf '%s\n%s\n' "$copied_file" "$setup_mark" >> .git/info/exclude
epic="$("$local_adapter/create.sh" epic "Drills" --size L --body x)"
epic_branch="$(epic_of "$epic")"
remote_branch "$epic_branch"; remote_commit "$epic_branch" drills.txt
epic_worktree="$("$plugin/scripts/steward.sh" claim "$epic" --branch "$epic_branch" 2>/dev/null)"
check "EpicClaimedOnItsEpicBranchInANewWorktree_GetsTheWorktreeCopyFiles: the pass builds in the claimed worktree, so the ignored files worktree_copy names must reach it as for any claim that adds a worktree" \
  '[ -n "$epic_worktree" ] && [ "$(cat "$epic_worktree/$copied_file")" = secret ]'
check "EpicClaimedOnItsEpicBranchInANewWorktree_RunsWorktreeSetup: the pass builds and tests in the claimed worktree, so worktree_setup must run there as for any claim that adds a worktree" \
  '[ -n "$epic_worktree" ] && [ "$(cat "$epic_worktree/$setup_mark")" = ran ]'

echo "epic PR claim: a task claimed on the base branch"
new_repo task_on_the_base
task="$(new_task "Tidy")"
"$plugin/scripts/steward.sh" claim "$task" --branch main >/dev/null 2>&1
check "TaskClaimedOnTheBaseBranch_ClaimsNoWorktree: only an epic on its own epic branch may stand on a branch other claims cut from, so a task naming the base must still be refused" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$task")" ]'

[ "$fails" -eq 0 ] && { echo "epic-pr-claim: ok"; exit 0; }
echo "epic-pr-claim: $fails failed"; exit 1
