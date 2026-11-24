#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh sets plugin, work, local_adapter, root and fails; the checks' conditions read the names set here
# epic-base.sh: the health job keeps an approved epic's branch up with its base, on the local
# adapter in throwaway repos with a bare origin. An epic branch more than behind_base commits behind
# its base gets the base merged in and pushed, as a merge commit whose second parent is the base; a
# dry run only says so. The base is an epic branch above the epic, else a base: line, else the
# config base. A branch in step or within behind_base, a base not on the remote and the task branch
# of a claimed parent are left alone. Each epic has an open child and no state, which the health
# job counts approved, as an epic whose children the owner made by hand. A merge that conflicts
# changes nothing and is said and notified once per set of conflicted files; a refused push is said
# once and merged on the run after the remote takes it again.
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
remote_commit_text() { git -C "$root/other" fetch -q origin && git -C "$root/other" checkout -q -B "$1" "origin/$1" && printf '%s\n' "$3" > "$root/other/$2" && git -C "$root/other" add -- "$2" && git -C "$root/other" commit -qm "$2" && git -C "$root/other" push -q origin "$1"; }
notify_on_the_desktop() { printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\npool_max: 8\nnotify:\n  desktop: true\njobs:\n  health:\n    behind_base: 1\n' > .flow/config.yaml; }
health_notifications_holding() {
  health_notifications_lines="$(grep -F 'flow: health' "$work/offline.log")"
  for health_notifications_text in "$@"; do health_notifications_lines="$(printf '%s\n' "$health_notifications_lines" | grep -F -- "$health_notifications_text")"; done
  printf '%s' "$health_notifications_lines" | grep -c .
}
health_line_holds() {
  health_line_file="$1"; shift; health_line_matches="$(cat "$health_line_file")"
  for health_line_text in "$@"; do health_line_matches="$(printf '%s\n' "$health_line_matches" | grep -F -- "$health_line_text")"; done
  [ -n "$health_line_matches" ]
}
parent_of() { git -C "$root/origin.git" rev-parse -q --verify "$1^$2" 2>/dev/null; }
first_parent=1
second_parent=2
one_notification=1
no_notification=0

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
nested_with_a_line="$(approved_epic "Goalkeeping" --body "$release_line" --parent "$parent_epic")"
remote_branch "$(epic_of "$nested_with_a_line")"
health_pass > "$work/bases.out"
check "EpicUnderAnEpicWithABranch_HasThatEpicBranchMergedIn: the epic's work starts from the epic above it, so that branch is its base, not main" \
  '[ -n "$(remote_tip "$(epic_of "$parent_epic")")" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$nested")")" "$second_parent")" = "$(remote_tip "$(epic_of "$parent_epic")")" ]'
check "EpicWithABaseLine_HasThatBranchMergedIn: the base: line names the branch the epic keeps up with" \
  '[ -n "$(remote_tip release)" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$on_release")")" "$second_parent")" = "$(remote_tip release)" ]'
check "EpicUnderAnEpicWithABranchAndABaseLine_HasTheEpicBranchAboveMergedIn: an epic branch above wins over a base: line, as it does for a child's base" \
  '[ -n "$(remote_tip "$(epic_of "$parent_epic")")" ] && [ "$(parent_of "$(remote_tip "$(epic_of "$nested_with_a_line")")" "$second_parent")" = "$(remote_tip "$(epic_of "$parent_epic")")" ]'

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

echo "epic base: a conflicting merge is said once and changes nothing"
new_repo conflict
notify_on_the_desktop
clashing="$(approved_epic "Tournaments" --body x)"
clashing_branch="$(epic_of "$clashing")"
remote_branch "$clashing_branch"
remote_commit_text "$clashing_branch" clash.txt "epic side"
remote_commit_text main clash.txt "main side"
remote_commit main main-one.txt
clashing_tip_before="$(remote_tip "$clashing_branch")"
clashing_behind="2 commits behind"
git fetch -q origin
: > "$work/offline.log"
health_pass --dry-run > "$work/conflict-dry.out"
check "HealthDryRunOnAConflictingEpicBranch_SaysWhatItWouldSay: a dry run shows the conflict the real run would report" \
  'health_line_holds "$work/conflict-dry.out" "would say" "$clashing_branch" "clash.txt"'
check "HealthDryRunOnAConflictingEpicBranch_NotifiesNothing: a dry run only says what it would do" \
  'grep -q "^health: " "$work/conflict-dry.out" && [ "$(health_notifications_holding "$clashing_branch")" = "$no_notification" ]'
health_pass --dry-run > "$work/conflict-dry-again.out"
check "HealthDryRunOnAConflictingEpicBranch_RecordsNothing: a second dry run still shows the conflict, so the first one marked nothing as said" \
  'health_line_holds "$work/conflict-dry-again.out" "would say" "$clashing_branch" "clash.txt"'
: > "$work/offline.log"
health_pass > "$work/conflict.out"
check "EpicBranchWhoseMergeConflicts_LeavesTheRemoteAsItWas: a conflicted merge is the owner's to resolve, so nothing is pushed" \
  '[ -n "$clashing_tip_before" ] && [ "$(remote_tip "$clashing_branch")" = "$clashing_tip_before" ]'
check "EpicBranchWhoseMergeConflicts_SaysTheEpicHowFarBehindAndTheFiles: the owner learns which branch, how far behind and which files to merge by hand" \
  'health_line_holds "$work/conflict.out" "$clashing_branch" "$clashing_behind" "clash.txt"'
check "EpicBranchWhoseMergeConflicts_Notifies: a conflict waits on the owner, so it reaches them away from the terminal" \
  '[ "$(health_notifications_holding "$clashing_branch" "$clashing_behind" "clash.txt")" = "$one_notification" ]'
remote_commit main main-two.txt
: > "$work/offline.log"
health_pass > "$work/conflict-again.out"
check "EpicBranchWhoseMergeStillConflicts_IsSaidOnce: a new base commit that leaves the conflicted files as they were is no new finding" \
  'grep -q "^health: " "$work/conflict-again.out" && ! grep -qF "clash.txt" "$work/conflict-again.out"'
check "EpicBranchWhoseMergeStillConflicts_NotifiesNothing: the owner was told already" \
  'grep -q "^health: " "$work/conflict-again.out" && [ "$(health_notifications_holding "$clashing_branch")" = "$no_notification" ]'
remote_commit_text "$clashing_branch" clash-two.txt "epic side"
remote_commit_text main clash-two.txt "main side"
: > "$work/offline.log"
health_pass > "$work/conflict-changed.out"
check "EpicBranchWhoseConflictedFilesChange_IsSaidAgain: a new conflicted file is a new finding" \
  'health_line_holds "$work/conflict-changed.out" "$clashing_branch" "clash-two.txt"'
check "EpicBranchWhoseConflictedFilesChange_NotifiesAgain: the owner hears of each new set of files to merge by hand" \
  '[ "$(health_notifications_holding "$clashing_branch" "clash-two.txt")" = "$one_notification" ]'

echo "epic base: a conflict merged by hand and met again is said again"
new_repo cleared
notify_on_the_desktop
cleared="$(approved_epic "Referees" --body x)"
cleared_branch="$(epic_of "$cleared")"
remote_branch "$cleared_branch"
remote_commit_text "$cleared_branch" clash.txt "epic side"
remote_commit_text main clash.txt "main side"
remote_commit main main-one.txt
health_pass > "$work/cleared-first.out"
git -C "$root/other" fetch -q origin && git -C "$root/other" checkout -q -B "$cleared_branch" "origin/$cleared_branch"
git -C "$root/other" merge -q -X ours --no-edit -m "merge main by hand" origin/main >/dev/null && git -C "$root/other" push -q origin "$cleared_branch"
health_pass > "$work/cleared-in-step.out"
remote_commit_text "$cleared_branch" clash.txt "epic side again"
remote_commit_text main clash.txt "main side again"
remote_commit main main-two.txt
health_pass > "$work/cleared-again.out"
check "EpicBranchMergedByHandAfterAConflict_HasTheSameConflictSaidAgain: a branch brought in step closes the old finding, so a later conflict in the same file is new" \
  'health_line_holds "$work/cleared-again.out" "$cleared_branch" "clash.txt"'

echo "epic base: a refused push is said once and merged once the remote takes it"
new_repo refused
refused="$(approved_epic "Transfers" --body x)"
refused_branch="$(epic_of "$refused")"
remote_branch "$refused_branch"
remote_commit main main-one.txt; remote_commit main main-two.txt
refused_tip_before="$(remote_tip "$refused_branch")"
printf '#!/bin/sh\nexit 1\n' > "$root/origin.git/hooks/pre-receive"; chmod +x "$root/origin.git/hooks/pre-receive"
health_pass > "$work/refused.out"
check "EpicBranchWhosePushIsRefused_LeavesTheRemoteAsItWas: the remote decides what the epic branch holds" \
  '[ -n "$refused_tip_before" ] && [ "$(remote_tip "$refused_branch")" = "$refused_tip_before" ]'
check "EpicBranchWhosePushIsRefused_IsSaidAndLeftForTheNextRun: the owner sees the merge did not land" \
  'health_line_holds "$work/refused.out" "$refused_branch" "could not push"'
health_pass > "$work/refused-again.out"
check "EpicBranchWhosePushIsStillRefused_IsSaidOnce: a protected epic branch is said once, not every run" \
  'grep -q "^health: " "$work/refused-again.out" && ! grep -qF "could not push" "$work/refused-again.out"'
rm "$root/origin.git/hooks/pre-receive"
health_pass > "$work/taken.out"
check "EpicBranchWhosePushIsTakenAgain_IsMerged: the next run after the remote takes pushes again brings the base in" \
  '[ -n "$(remote_tip main)" ] && git -C "$root/origin.git" merge-base --is-ancestor "$(remote_tip main)" "$(remote_tip "$refused_branch")"'

if [ "$fails" -eq 0 ]; then echo "epic-base: ok"; else echo "epic-base: $fails failed"; exit 1; fi
