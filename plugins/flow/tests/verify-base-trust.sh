#!/bin/sh
# shellcheck disable=SC2154 # the fixtures sourced below set plugin, here, work, worktree, item and reports
# verify-base-trust.sh: the comparisons verify refuses, on the local adapter in throwaway repos. A
# base that is the item's own branch (by the claim, by --base, at HEAD under another name, beside a
# tag of the branch's name or from a detached HEAD), a claim base that differs from the item's
# record (also on an epic slice), a HEAD that is not the item's branch and a HEAD verify cannot
# read each fail the `changed files` check, run every check with paths, reuse no kept pass and
# raise the feel test. Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"
. "$here/_verify_base_fixture.sh"

changed_source_item own-branch-claim "$failing_scoped_test" committed
task_branch="$(current_branch)"
set_claim_base "$item" "$task_branch"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_claim_result=$?
check "ClaimBaseRewrittenToTheItemsOwnBranch_ExitsFailingOnTheRefusal because a base that hides every committed change cannot prove the change" \
  '[ "$own_branch_claim_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_ReportsFail because the report reader must not read a hidden change as green" \
  '[ "$(report_status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_SaysVerifyCannotTrustTheComparison because the reader must see the run was refused, not short of a file" \
  'summary_names_the_cause "verify cannot trust the comparison, so it cannot pass: "'
check "ClaimBaseRewrittenToTheItemsOwnBranch_NamesTheOwnBranch because the reader must know why the base is refused" \
  "summary_names_the_cause \"the comparison base $task_branch is the item's own branch\""
check "ClaimBaseRewrittenToTheItemsOwnBranch_RunsTheScopedTest because a hiding base cannot show that nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item own-branch-reuse "$whole_tree_test" committed
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_first_status="$(report_status)"
set_claim_base "$item" "$(current_branch)"
verify >/dev/null 2>&1
check "ItemBeforeItsClaimBaseIsRewritten_Passes because a no-reuse check proves nothing unless a kept pass was there to reuse" \
  '[ "$own_branch_first_status" = pass ]'
check "ClaimBaseRewrittenToTheItemsOwnBranchAfterAPass_FailsTheChangedFilesCheck because the rewritten base is refused on the second run" \
  '[ "$(check_field "changed files" status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranchAfterAPass_ReusesNoPass because a kept pass proved a change list the refused base cannot" \
  '[ -z "$(check_field "tests whole" reused_from)" ]'

changed_source_item own-branch-no-record "$failing_scoped_test" committed
"$plugin/scripts/state.sh" set "$item" base= >/dev/null
set_claim_base "$item" "$(current_branch)"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_no_record_result=$?
check "ClaimBaseOnTheItemsOwnBranchWithNoRecordedBase_ExitsFailingOnTheRefusal because a base that hides the work is refused with no record to compare" \
  '[ "$own_branch_no_record_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'

changed_source_item claim-disagrees "$failing_scoped_test" committed
commit_notes
git -C "$worktree" branch hidden-base HEAD~1
set_claim_base "$item" hidden-base
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
claim_disagrees_result=$?
check "ClaimBaseDiffersFromTheItemsRecord_ExitsFailingOnTheRefusal because verify cannot tell which of the two bases is the item's" \
  '[ "$claim_disagrees_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "ClaimBaseDiffersFromTheItemsRecord_ReportsFail because the report reader must not read an unproven change as green" \
  '[ "$(report_status)" = fail ]'
check "ClaimBaseDiffersFromTheItemsRecord_NamesBothBases because the reader must see the two names to fix the claim" \
  "summary_names_the_cause \"the claim names the base hidden-base, the item's record names main\""
check "ClaimBaseDiffersFromTheItemsRecord_ReportsNoBase because verify picks neither of the two bases" \
  '[ -z "$(report_base)" ]'
check "ClaimBaseDiffersFromTheItemsRecord_GivesTheCommandUnavailable because a command must not narrow its run to a base verify did not pick" \
  '[ "$(check_field "tests scoped" command)" = "false unavailable" ]'
check "ClaimBaseDiffersFromTheItemsRecord_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item claim-disagrees-reuse "$whole_tree_test" committed
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
claim_disagrees_first_status="$(report_status)"
git -C "$worktree" branch elsewhere HEAD
set_claim_base "$item" elsewhere
verify >/dev/null 2>&1
check "ItemBeforeItsClaimNamesAnotherBase_Passes because a no-reuse check proves nothing unless a kept pass was there to reuse" \
  '[ "$claim_disagrees_first_status" = pass ]'
check "ClaimBaseDiffersFromTheItemsRecordAfterAPass_FailsTheChangedFilesCheck because the disputed base is refused on the second run" \
  '[ "$(check_field "changed files" status)" = fail ]'
check "ClaimBaseDiffersFromTheItemsRecordAfterAPass_ReusesNoPass because a kept pass proved a change list measured from one base verify cannot trust" \
  '[ -z "$(check_field "tests whole" reused_from)" ]'

changed_source_item own-branch-option "$failing_scoped_test" committed
task_branch="$(current_branch)"
verify --base "$task_branch" >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_option_result=$?
check "BaseOptionNamingTheItemsOwnBranch_ExitsFailingOnTheRefusal because the caller's choice of base still cannot hide the committed change" \
  '[ "$own_branch_option_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "BaseOptionNamingTheItemsOwnBranch_NamesTheOwnBranch because the reader must know why the caller's base is refused" \
  "summary_names_the_cause \"the comparison base $task_branch is the item's own branch\""
check "BaseOptionNamingTheItemsOwnBranch_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item head-alias "$failing_scoped_test" committed
git -C "$worktree" branch head-alias HEAD
verify --base head-alias >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
head_alias_result=$?
check "BaseOptionAtTheItemsHeadCommitUnderAnotherName_ExitsFailingOnTheRefusal because a base at HEAD hides every commit the branch holds" \
  '[ "$head_alias_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "BaseOptionAtTheItemsHeadCommitUnderAnotherName_NamesTheOwnBranch because the reader must know why the base is refused" \
  "summary_names_the_cause \"the comparison base head-alias is the item's own branch\""

changed_source_item detached-head "$failing_scoped_test" committed
task_branch="$(current_branch)"
git -C "$worktree" checkout -q --detach && commit_notes
verify --base "$task_branch" >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
detached_head_result=$?
check "BaseOptionNamingTheTaskBranchFromADetachedHead_ExitsFailingOnTheRefusal because the item's record names that branch as its own" \
  '[ "$detached_head_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "BaseOptionNamingTheTaskBranchFromADetachedHead_NamesTheOwnBranch because the reader must know why the base is refused" \
  "summary_names_the_cause \"the comparison base $task_branch is the item's own branch\""

changed_source_item tag-like-the-task-branch "$failing_scoped_test" committed
task_branch="$(current_branch)"
"$plugin/scripts/state.sh" set "$item" base= branch= >/dev/null
git -C "$worktree" tag "$task_branch" HEAD
set_claim_base "$item" "$task_branch"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
tag_like_the_task_branch_result=$?
check "ClaimBaseOnTheTaskBranchBesideATagOfItsName_ExitsFailingOnTheRefusal because the tag does not change which branch HEAD is on" \
  '[ "$tag_like_the_task_branch_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "ClaimBaseOnTheTaskBranchBesideATagOfItsName_NamesTheOwnBranch because the reader must know why the base is refused" \
  "summary_names_the_cause \"the comparison base $task_branch is the item's own branch\""

changed_source_item detached-off-the-branch "$failing_scoped_test" committed
task_branch="$(current_branch)"
git -C "$worktree" checkout -q --detach HEAD~1
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
detached_off_the_branch_result=$?
check "HeadDetachedBehindTheItemsBranch_ExitsFailingOnTheRefusal because the commit verified is not the item's work" \
  '[ "$detached_off_the_branch_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "HeadDetachedBehindTheItemsBranch_NamesTheItemsBranch because the reader must know which branch to check out" \
  "summary_names_the_cause \"HEAD is not the item's branch $task_branch\""

changed_source_item on-another-branch "$failing_scoped_test" committed
task_branch="$(current_branch)"
git -C "$worktree" checkout -q -b another-branch HEAD~1
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
on_another_branch_result=$?
check "HeadOnAnotherBranchThanTheItems_ExitsFailingOnTheRefusal because the branch verified is not the item's work" \
  '[ "$on_another_branch_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "HeadOnAnotherBranchThanTheItems_NamesTheItemsBranch because the reader must know which branch to check out" \
  "summary_names_the_cause \"HEAD is not the item's branch $task_branch\""

changed_source_item task-branch-gone "$failing_scoped_test" committed
task_branch="$(current_branch)"
git -C "$worktree" checkout -q -b renamed-branch && git -C "$worktree" branch -q -D "$task_branch"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
task_branch_gone_result=$?
check "ItemsBranchDeletedUnderHead_ExitsFailingOnTheRefusal because a missing branch cannot show HEAD is the item's work" \
  '[ "$task_branch_gone_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'

changed_source_item replaced-base "$failing_scoped_test" committed
replaced_base_commit="$(git -C "$worktree" merge-base refs/heads/main HEAD)"
replaced_base_parents=""; for parent in $(git -C "$worktree" log -1 --format=%P "$replaced_base_commit"); do replaced_base_parents="$replaced_base_parents -p $parent"; done
# shellcheck disable=SC2086 # each parent is one -p argument
git -C "$worktree" replace "$replaced_base_commit" "$(git -C "$worktree" commit-tree "$(git -C "$worktree" rev-parse 'HEAD^{tree}')" $replaced_base_parents -m forged)"
verify >/dev/null 2>&1
check "BaseCommitReplacedByOneHoldingTheWork_FailsTheScopedTestAlone because a replace ref must not hide the committed change from the comparison" \
  '[ "$(failed_checks)" = "tests scoped" ]'

real_git="$(command -v git)"; stand_in_git="$work/stand-in-git"; mkdir -p "$stand_in_git"
cat > "$stand_in_git/git" <<'STUB'
#!/bin/sh
[ "$*" != "$FAILING_GIT_ARGUMENTS" ] || { echo "fatal: stand-in failure of git $*" >&2; exit 128; }
exec "$REAL_GIT" "$@"
STUB
chmod +x "$stand_in_git/git"
verify_with_failing_git() {
  (cd "$worktree" && env FAILING_GIT_ARGUMENTS="$1" REAL_GIT="$real_git" PATH="$stand_in_git:$PATH" \
    "$plugin/scripts/verify.sh" "$item" >/dev/null 2>&1)
}
changed_source_item head-commit-unreadable "$failing_scoped_test" committed
verify_with_failing_git 'rev-parse --verify -q HEAD^{commit}'
# shellcheck disable=SC2034 # the check's condition reads it
head_commit_unreadable_result=$?
check "HeadCommitUnreadable_ExitsFailingOnTheRefusal because no comparison holds without the commit it measures" \
  '[ "$head_commit_unreadable_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "HeadCommitUnreadable_NamesTheCause because the reader must know verify could not read HEAD" \
  'summary_names_the_cause "verify cannot read HEAD"'
changed_source_item head-branch-unreadable "$failing_scoped_test" committed
verify_with_failing_git 'symbolic-ref -q HEAD'
# shellcheck disable=SC2034 # the check's condition reads it
head_branch_unreadable_result=$?
check "HeadBranchUnreadable_ExitsFailingOnTheRefusal because a branch git cannot name may be the item's own" \
  '[ "$head_branch_unreadable_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "HeadBranchUnreadable_NamesTheCause because the reader must know verify could not read HEAD" \
  'summary_names_the_cause "verify cannot read HEAD"'

new_item slice-dispute ""
slice_parent_branch="$(current_branch)"; item="$(claimed_slice_of "$item")"
worktree="$("$plugin/scripts/steward.sh" find "$item")"
# shellcheck disable=SC2034 # the fixture's report readers read it
reports="$worktree/.flow/reports/$(slug "$item")"
scoped_source_change "$worktree"
git -C "$worktree" add .standards/config.json source/file.sh && git -C "$worktree" commit -qm "slice change"
set_claim_base "$item" main
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
slice_dispute_result=$?
check "EpicSliceWhoseClaimNamesAnotherBaseThanItsRecord_ExitsFailingOnTheRefusal because the slice's record names its parent's branch" \
  '[ "$slice_dispute_result" -eq "$verify_failed_exit" ] && [ "$(failed_checks)" = "$refused_checks" ]'
check "EpicSliceWhoseClaimNamesAnotherBaseThanItsRecord_NamesBothBases because the reader must see the two names to fix the claim" \
  "summary_names_the_cause \"the claim names the base main, the item's record names $slice_parent_branch\""
exit "$((fails > 0))"
