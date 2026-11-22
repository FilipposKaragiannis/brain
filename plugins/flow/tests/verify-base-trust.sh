#!/bin/sh
# verify-base-trust.sh: the comparison bases verify refuses, on the local adapter in throwaway
# repos. A base that is the item's own branch, by the claim, by --base, at HEAD under another name
# or from a detached HEAD, and a claim base that differs from the item's record, each fail the
# `changed files` check, run every check with paths, reuse no kept pass and raise the feel test. A
# tag named like the base never stands in for it. An item with no commits yet, an item nothing
# records a base for and an epic slice on its parent's branch fail on their own checks alone.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

check_field() { python3 -c 'import json,sys; found=[check for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]]; print(found[0].get(sys.argv[3], "") if found else "no such check")' "$reports/verify.json" "$1" "$2"; }
feel_test() { json_value feel_test < "$reports/verify.json"; }
report_base() { json_value base < "$reports/verify.json"; }
changed_source_item() {
  new_item "$1" ""
  printf 'feel_test_paths:\n  - ui/**\n' >> .flow/config.yaml
  mkdir -p "$worktree/.standards" "$worktree/source"
  printf '%s\n' "$2" > "$worktree/.standards/config.json"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "standards"
  echo change > "$worktree/source/file.sh"
  case "$3" in
    committed) git -C "$worktree" add source/file.sh && git -C "$worktree" commit -qm "source change" ;;
    staged) git -C "$worktree" add source/file.sh ;;
  esac
}
commit_notes() { echo note > "$worktree/notes.txt" && git -C "$worktree" add notes.txt && git -C "$worktree" commit -qm "notes"; }
current_branch() { git -C "$worktree" symbolic-ref --short HEAD; }
expect_summary() { printf '%s\n' "$1" > "$work/expected-summary"; }
summary_names_the_cause() { check_field "changed files" summary | grep -qF -f "$work/expected-summary"; }
failing_scoped_test='{"test":[{"name":"scoped","command":"false {verify_base}","paths":["source/**"]}]}'
whole_tree_test='{"test":[{"name":"whole","command":"true"}]}'
# shellcheck disable=SC2034 # the check's condition reads it
verify_failed_exit=1

changed_source_item own-branch-claim "$failing_scoped_test" committed
expect_summary "the comparison base $(current_branch) is the item's own branch"
set_claim_base "$item" "$(current_branch)"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_claim_result=$?
check "ClaimBaseRewrittenToTheItemsOwnBranch_ExitsFailing because a base that hides every committed change cannot prove the change" \
  '[ "$own_branch_claim_result" -eq "$verify_failed_exit" ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_ReportsFail because the report reader must not read a hidden change as green" \
  '[ "$(report_status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_NamesTheOwnBranch because the reader must know why the base is refused" \
  'summary_names_the_cause'
check "ClaimBaseRewrittenToTheItemsOwnBranch_RunsTheScopedTest because a hiding base cannot show that nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item own-branch-reuse "$whole_tree_test" committed
verify >/dev/null 2>&1
set_claim_base "$item" "$(current_branch)"
verify >/dev/null 2>&1
check "ClaimBaseRewrittenToTheItemsOwnBranchAfterAPass_ReusesNoPass because a kept pass proved a change list the refused base cannot" \
  '[ -z "$(check_field "tests whole" reused_from)" ]'

changed_source_item own-branch-no-record "$failing_scoped_test" committed
"$local_adapter/write-state.sh" "$item" base= >/dev/null
set_claim_base "$item" "$(current_branch)"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_no_record_result=$?
check "ClaimBaseOnTheItemsOwnBranchWithNoRecordedBase_ExitsFailing because a base that hides the work is refused with no record to compare" \
  '[ "$own_branch_no_record_result" -eq "$verify_failed_exit" ]'
check "ClaimBaseOnTheItemsOwnBranchWithNoRecordedBase_RunsTheScopedTest because the hiding base must not skip a test under the changed paths" \
  '[ "$(check_field "tests scoped" status)" = fail ]'

changed_source_item claim-disagrees "$failing_scoped_test" committed
commit_notes
git -C "$worktree" branch hidden-base HEAD~1
set_claim_base "$item" hidden-base
expect_summary "the claim names the base hidden-base, the item's record names main"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
claim_disagrees_result=$?
check "ClaimBaseDiffersFromTheItemsRecord_ExitsFailing because verify cannot tell which of the two bases is the item's" \
  '[ "$claim_disagrees_result" -eq "$verify_failed_exit" ]'
check "ClaimBaseDiffersFromTheItemsRecord_ReportsFail because the report reader must not read an unproven change as green" \
  '[ "$(report_status)" = fail ]'
check "ClaimBaseDiffersFromTheItemsRecord_NamesBothBases because the reader must see the two names to fix the claim" \
  'summary_names_the_cause'
check "ClaimBaseDiffersFromTheItemsRecord_ReportsNoBase because verify picks neither of the two bases" \
  '[ -z "$(report_base)" ]'
check "ClaimBaseDiffersFromTheItemsRecord_GivesTheCommandUnavailable because a command must not narrow its run to a base verify did not pick" \
  '[ "$(check_field "tests scoped" command)" = "false unavailable" ]'
check "ClaimBaseDiffersFromTheItemsRecord_RunsTheScopedTest because verify must not trust a base it cannot tell from the record" \
  '[ "$(check_field "tests scoped" status)" = fail ]'
check "ClaimBaseDiffersFromTheItemsRecord_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item claim-disagrees-reuse "$whole_tree_test" committed
verify >/dev/null 2>&1
git -C "$worktree" branch elsewhere HEAD
set_claim_base "$item" elsewhere
verify >/dev/null 2>&1
check "ClaimBaseDiffersFromTheItemsRecordAfterAPass_ReusesNoPass because a kept pass proved a change list measured from one base verify cannot trust" \
  '[ -z "$(check_field "tests whole" reused_from)" ]'

changed_source_item own-branch-option "$failing_scoped_test" committed
expect_summary "the comparison base $(current_branch) is the item's own branch"
verify --base "$(current_branch)" >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_option_result=$?
check "BaseOptionNamingTheItemsOwnBranch_ExitsFailing because the caller's choice of base still cannot hide the committed change" \
  '[ "$own_branch_option_result" -eq "$verify_failed_exit" ]'
check "BaseOptionNamingTheItemsOwnBranch_NamesTheOwnBranch because the reader must know why the caller's base is refused" \
  'summary_names_the_cause'
check "BaseOptionNamingTheItemsOwnBranch_RunsTheScopedTest because a hiding base cannot show that nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = fail ]'
check "BaseOptionNamingTheItemsOwnBranch_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item head-alias "$failing_scoped_test" committed
git -C "$worktree" branch head-alias HEAD
expect_summary "the comparison base head-alias is the item's own branch"
verify --base head-alias >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
head_alias_result=$?
check "BaseOptionAtTheItemsHeadCommitUnderAnotherName_ExitsFailing because a base at HEAD hides every commit the branch holds" \
  '[ "$head_alias_result" -eq "$verify_failed_exit" ]'
check "BaseOptionAtTheItemsHeadCommitUnderAnotherName_NamesTheOwnBranch because the reader must know why the base is refused" \
  'summary_names_the_cause'
check "BaseOptionAtTheItemsHeadCommitUnderAnotherName_RunsTheScopedTest because a hiding base cannot show that nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = fail ]'

changed_source_item detached-head "$failing_scoped_test" committed
task_branch="$(current_branch)"
git -C "$worktree" checkout -q --detach && commit_notes
expect_summary "the comparison base $task_branch is the item's own branch"
verify --base "$task_branch" >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
detached_head_result=$?
check "BaseOptionNamingTheTaskBranchFromADetachedHead_ExitsFailing because the item's record names that branch as its own" \
  '[ "$detached_head_result" -eq "$verify_failed_exit" ]'
check "BaseOptionNamingTheTaskBranchFromADetachedHead_NamesTheOwnBranch because the reader must know why the base is refused" \
  'summary_names_the_cause'
check "BaseOptionNamingTheTaskBranchFromADetachedHead_RunsTheScopedTest because the task branch hides the committed change" \
  '[ "$(check_field "tests scoped" status)" = fail ]'

changed_source_item tag-like-the-base "$failing_scoped_test" committed
git -C "$worktree" tag main HEAD && commit_notes
verify >/dev/null 2>&1
check "TagNamedLikeTheBaseAtTheWork_FailsOnTheScopedTestAlone because verify compares with the base branch, not a tag of its name" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item tag-like-the-remote-base "$failing_scoped_test" committed
git init -q --bare "$root/origin.git" && git remote add origin "$root/origin.git" && git push -q origin main
git -C "$worktree" tag origin/main HEAD && commit_notes
verify >/dev/null 2>&1
check "TagNamedLikeTheRemoteBaseAtTheWork_FailsOnTheScopedTestAlone because verify compares with the remote's branch, not a tag of its name" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item no-commits-yet "$failing_scoped_test" staged
git -C "$worktree" reset -q --soft main
verify >/dev/null 2>&1
check "ItemWithNoCommitsYet_FailsOnItsScopedTestAlone because a base at HEAD hides nothing when the branch holds no commit of its own" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item no-commits-untracked "$failing_scoped_test" untracked
git -C "$worktree" reset -q main
verify >/dev/null 2>&1
check "ItemWithNoCommitsYetAndUntrackedFiles_FailsOnItsScopedTestAlone because untracked files are changes and a base at HEAD hides nothing" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item no-recorded-base "$failing_scoped_test" committed
"$local_adapter/write-state.sh" "$item" base= >/dev/null
rm -f "$worktree/.flow/claim.json"
verify >/dev/null 2>&1
check "NoClaimAndNoRecordedBase_FailsOnItsScopedTestAlone because the config base is the base of an item nothing records one for" \
  '[ "$(failed_checks)" = "tests scoped" ]'

claimed_slice_of() {
  claimed_slice_item="$("$local_adapter/create.sh" task "Slice of $1" --size S --body x --parent "$1")" && "$plugin/scripts/next.sh" "$claimed_slice_item" >/dev/null 2>&1 && printf '%s' "$claimed_slice_item"
}
scoped_source_change() { mkdir -p "$1/.standards" "$1/source" && printf '%s\n' "$failing_scoped_test" > "$1/.standards/config.json" && echo change > "$1/source/file.sh"; }
new_item slice ""
# shellcheck disable=SC2034 # the check's condition reads it
slice_parent_branch="$(current_branch)"; item="$(claimed_slice_of "$item")"
worktree="$("$plugin/scripts/steward.sh" find "$item")"; reports="$worktree/.flow/reports/$(slug "$item")"
scoped_source_change "$worktree"
git -C "$worktree" add .standards/config.json source/file.sh && git -C "$worktree" commit -qm "slice change"
verify >/dev/null 2>&1
check "EpicSliceOnItsParentsBranch_ComparesWithTheParentsBranch because the slice merges into its parent's branch" \
  '[ "$(report_base)" = "$slice_parent_branch" ]'
check "EpicSliceOnItsParentsBranch_FailsOnItsScopedTestAlone because the parent's branch is the slice's recorded base" \
  '[ "$(failed_checks)" = "tests scoped" ]'

new_item older-slice ""
item="$(claimed_slice_of "$item")"
worktree="$("$plugin/scripts/steward.sh" find "$item")"; reports="$worktree/.flow/reports/$(slug "$item")"
scoped_source_change "$worktree"
"$local_adapter/write-state.sh" "$item" base= >/dev/null
verify >/dev/null 2>&1
check "OlderEpicSliceWithNoCommitsYetAndNoRecordedBase_FailsOnItsScopedTestAlone because its claim names the parent's branch, which holds HEAD" \
  '[ "$(failed_checks)" = "tests scoped" ]'
exit "$((fails > 0))"
