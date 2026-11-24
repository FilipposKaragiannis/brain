#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh sets plugin, work, local_adapter, root and fails; the checks' conditions read the names set here
# epic-base.sh: the health job keeps an approved epic's branch up with its base, on the local
# adapter in throwaway repos with a bare origin. An epic branch more than behind_base commits behind
# its base gets the base merged in and pushed, as a merge commit whose second parent is the base; a
# dry run only says so. The base is an epic branch above the epic, else a base: line, else the
# config base. A branch in step or within behind_base, a base not on the remote and the task branch
# of a claimed parent are left alone. Each epic has an open child and no state, which the health
# job counts approved, as an epic whose children the owner made by hand.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
health_pass() { "$plugin/scripts/steward.sh" health "$@" 2>&1; }
approved_epic() {
  approved_title="$1"; shift
  approved_id="$("$local_adapter/create.sh" epic "$approved_title" "$@")"
  new_task "$approved_title child" "$approved_id" >/dev/null
  printf '%s' "$approved_id"
}
parent_of() { git -C "$root/origin.git" rev-parse -q --verify "$1^$2" 2>/dev/null; }
first_parent=1
second_parent=2

echo "epic base: an epic branch past behind_base gets its base merged in"
new_repo behind
at_old_main="$(approved_epic "Physics" --body x)"
remote_branch "$(epic_of "$at_old_main")"
with_own_work="$(approved_epic "Audio" --body x)"
remote_branch "$(epic_of "$with_own_work")"; remote_commit "$(epic_of "$with_own_work")" audio-own.txt
old_main_tip_before="$(remote_tip "$(epic_of "$at_old_main")")"
own_work_tip_before="$(remote_tip "$(epic_of "$with_own_work")")"
remote_commit main main-one.txt; remote_commit main main-two.txt
git fetch -q origin
health_pass --dry-run > "$work/behind-dry.out"
check "HealthDryRunOnAnEpicBranchBehind_PushesNothing: a dry run only says what it would do" \
  '[ -n "$old_main_tip_before" ] && [ "$(remote_tip "$(epic_of "$at_old_main")")" = "$old_main_tip_before" ]'
check "HealthDryRunOnAnEpicBranchBehind_SaysWhatItWouldMerge: the owner sees the base, the epic branch and how far behind it is" \
  'grep -qF "would merge origin/main into $(epic_of "$at_old_main") (2 commits behind)" "$work/behind-dry.out"'
health_pass > "$work/behind.out"
check "EpicBranchPastBehindBaseWithACleanMerge_HasTheBaseMergedInAndPushed: the children start from an epic branch that holds the default branch's newest commits" \
  '[ -n "$(remote_tip main)" ] && git -C "$root/origin.git" merge-base --is-ancestor "$(remote_tip main)" "$(remote_tip "$(epic_of "$at_old_main")")"'
check "EpicBranchMergedByTheHealthJob_HasTheBaseAsItsSecondParent: a merge commit, never a fast-forward, keeps the base apart from the epic's own history" \
  '[ -n "$(remote_tip main)" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$at_old_main")")" "$second_parent")" = "$(remote_tip main)" ]'
check "EpicBranchMergedByTheHealthJob_HasItsOldTipAsItsFirstParent: the merge goes onto the epic branch, so its history comes first" \
  '[ -n "$old_main_tip_before" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$at_old_main")")" "$first_parent")" = "$old_main_tip_before" ]'
check "EpicBranchWithCommitsOfItsOwn_KeepsThemAfterTheMerge: the epic's own commit is the merge's first parent" \
  '[ -n "$own_work_tip_before" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$with_own_work")")" "$first_parent")" = "$own_work_tip_before" ]'

echo "epic base: an epic branch in step or within behind_base is left alone"
new_repo still
within="$(approved_epic "Rendering" --body x)"
remote_branch "$(epic_of "$within")"
remote_commit main main-one.txt
in_step="$(approved_epic "Netcode" --body x)"
remote_branch "$(epic_of "$in_step")"
within_tip_before="$(remote_tip "$(epic_of "$within")")"
in_step_tip_before="$(remote_tip "$(epic_of "$in_step")")"
health_pass > "$work/still.out"
check "EpicBranchInStepWithItsBase_IsLeftAlone: there is nothing to merge" \
  '[ -n "$in_step_tip_before" ] && [ "$(remote_tip "$(epic_of "$in_step")")" = "$in_step_tip_before" ]'
check "EpicBranchInStepWithItsBase_IsNotNamed: a branch with nothing to merge is no finding" \
  'grep -q "^health: " "$work/still.out" && ! grep -qF -e "$(epic_of "$in_step")" -e "$in_step:" "$work/still.out"'
check "EpicBranchWithinBehindBase_IsLeftAlone: one commit behind with behind_base 1 is not past it" \
  '[ -n "$within_tip_before" ] && [ "$(remote_tip "$(epic_of "$within")")" = "$within_tip_before" ]'

echo "epic base: the base is an epic branch above, else a base: line"
new_repo bases
parent_epic="$(approved_epic "Gameplay" --body x)"
remote_branch "$(epic_of "$parent_epic")"
nested="$(approved_epic "Ball physics" --body x --parent "$parent_epic")"
remote_branch "$(epic_of "$nested")"
remote_commit "$(epic_of "$parent_epic")" gameplay-one.txt; remote_commit "$(epic_of "$parent_epic")" gameplay-two.txt
remote_branch release
release_line="base: release"
on_release="$(approved_epic "Hotfixes" --body "$release_line")"
remote_branch "$(epic_of "$on_release")"
remote_commit release release-one.txt; remote_commit release release-two.txt
health_pass > "$work/bases.out"
check "EpicUnderAnEpicWithABranch_HasThatEpicBranchMergedIn: the epic's work starts from the epic above it, so that branch is its base, not main" \
  '[ -n "$(remote_tip "$(epic_of "$parent_epic")")" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$nested")")" "$second_parent")" = "$(remote_tip "$(epic_of "$parent_epic")")" ]'
check "EpicWithABaseLine_HasThatBranchMergedIn: the base: line names the branch the epic keeps up with" \
  '[ -n "$(remote_tip release)" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$on_release")")" "$second_parent")" = "$(remote_tip release)" ]'

echo "epic base: a base not on the remote is left alone"
new_repo missing
missing_line="base: missing"
on_missing="$(approved_epic "Leagues" --body "$missing_line")"
remote_branch "$(epic_of "$on_missing")"
missing_tip_before="$(remote_tip "$(epic_of "$on_missing")")"
remote_commit main main-one.txt; remote_commit main main-two.txt
health_pass > "$work/missing.out"
check "EpicWhoseBaseIsNotOnTheRemote_IsLeftAlone: the health job never falls back to main for an epic whose base: line names a missing branch" \
  '[ -n "$missing_tip_before" ] && [ "$(remote_tip "$(epic_of "$on_missing")")" = "$missing_tip_before" ]'

echo "epic base: the task branch of a claimed parent is left alone"
new_repo claimed
parent_task="$(new_task "Stadium list")"
under_task="$(approved_epic "Stadiums" --body x --parent "$parent_task")"
remote_branch "$(epic_of "$under_task")"
under_task_tip_before="$(remote_tip "$(epic_of "$under_task")")"
parent_worktree="$("$plugin/scripts/steward.sh" claim "$parent_task")"
for parent_file in stadium-one.txt stadium-two.txt; do
  printf '%s\n' "$parent_file" > "$parent_worktree/$parent_file"
  git -C "$parent_worktree" add -- "$parent_file" && git -C "$parent_worktree" commit -qm "$parent_file"
done
parent_task_branch="$(git -C "$parent_worktree" symbolic-ref --short HEAD)"
git -C "$parent_worktree" push -q origin "$parent_task_branch"
health_pass > "$work/claimed.out"
check "EpicWhoseParentHoldsATaskClaim_HasThatTaskBranchOnTheRemote: the task branch must be there to merge, or the next check proves nothing" \
  '[ -n "$(remote_tip "$parent_task_branch")" ] && [ "$(remote_tip "$parent_task_branch")" != "$under_task_tip_before" ]'
check "EpicWhoseParentHoldsATaskClaim_IsLeftAlone: task work reaches an epic branch through its PR, never through the health job" \
  '[ -n "$under_task_tip_before" ] && [ "$(remote_tip "$(epic_of "$under_task")")" = "$under_task_tip_before" ]'

if [ "$fails" -eq 0 ]; then echo "epic-base: ok"; else echo "epic-base: $fails failed"; exit 1; fi
