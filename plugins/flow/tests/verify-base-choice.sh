#!/bin/sh
# shellcheck disable=SC2154 # the fixtures sourced below set plugin, here, root, worktree, item and reports
# verify-base-choice.sh: the comparison base verify picks, on the local adapter in throwaway repos:
# the record's base when there is no claim, the --base value over a claim and a record that
# disagree, the remote's branch over a local one that holds the work, and never a tag of the base's
# name. An item with no commits yet, one nothing records a base for and epic slices on their
# parent's branch fail on their own checks alone. Exit 0 when every check passes, 1 on any
# failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"
. "$here/_verify_base_fixture.sh"

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

changed_source_item remote-behind-local "$failing_scoped_test" committed
git init -q --bare "$root/origin.git" && git remote add origin "$root/origin.git" && git push -q origin main
git merge -q --ff-only "$(current_branch)"
# shellcheck disable=SC2034 # the check's condition reads it
remote_base_commit="$(git rev-parse refs/remotes/origin/main)"
verify >/dev/null 2>&1
check "BaseWhoseLocalBranchHoldsTheWork_ComparesWithTheRemoteBranch because the remote's branch is the one the change must reach" \
  '[ "$(check_field "tests scoped" command)" = "false $remote_base_commit" ]'
check "BaseWhoseLocalBranchHoldsTheWork_FailsOnTheScopedTestAlone because the remote's branch lacks the item's commits" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item no-commits-yet "$failing_scoped_test" staged
git -C "$worktree" reset -q --soft main
verify >/dev/null 2>&1
check "ItemWithNoCommitsYet_FailsOnItsScopedTestAlone because a base at HEAD hides nothing when the branch holds no commit of its own" \
  '[ "$(failed_checks)" = "tests scoped" ]'
check "ItemWithNoCommitsYet_HasNoFeelTest because nothing changed under the feel-test paths" \
  '[ "$(feel_test)" = false ]'

changed_source_item no-commits-untracked "$failing_scoped_test" untracked
git -C "$worktree" reset -q main
verify >/dev/null 2>&1
check "ItemWithNoCommitsYetAndUntrackedFiles_FailsOnItsScopedTestAlone because untracked files are changes and a base at HEAD hides nothing" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item no-recorded-base "$failing_scoped_test" committed
"$plugin/scripts/state.sh" set "$item" base= >/dev/null
rm -f "$worktree/.flow/claim.json"
verify >/dev/null 2>&1
check "NoClaimAndNoRecordedBase_FailsOnItsScopedTestAlone because the config base is the base of an item nothing records one for" \
  '[ "$(failed_checks)" = "tests scoped" ]'
check "NoClaimAndNoRecordedBase_HasNoFeelTest because nothing changed under the feel-test paths" \
  '[ "$(feel_test)" = false ]'

changed_source_item no-claim "$failing_scoped_test" committed
git branch recorded-base main
"$plugin/scripts/state.sh" set "$item" base=recorded-base >/dev/null
rm -f "$worktree/.flow/claim.json"
verify >/dev/null 2>&1
check "NoClaimAndARecordedBase_ComparesWithTheRecordedBase because with no claim the record is all verify has to go by" \
  '[ "$(report_base)" = recorded-base ]'
check "NoClaimAndARecordedBase_FailsOnItsScopedTestAlone because the recorded base lacks the item's commits" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item option-over-a-dispute "$failing_scoped_test" committed
git -C "$worktree" branch elsewhere HEAD
set_claim_base "$item" elsewhere
verify --base main >/dev/null 2>&1
check "BaseOptionWhileTheClaimAndTheRecordDisagree_ComparesWithTheGivenBase because the caller's base settles which base verify uses" \
  '[ "$(report_base)" = main ]'
check "BaseOptionWhileTheClaimAndTheRecordDisagree_FailsOnItsScopedTestAlone because a given base leaves nothing in dispute" \
  '[ "$(failed_checks)" = "tests scoped" ]'

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
worktree="$("$plugin/scripts/steward.sh" find "$item")"
# shellcheck disable=SC2034 # the fixture's report readers read it
reports="$worktree/.flow/reports/$(slug "$item")"
scoped_source_change "$worktree"
"$plugin/scripts/state.sh" set "$item" base= >/dev/null
verify >/dev/null 2>&1
check "OlderEpicSliceWithNoCommitsYetAndNoRecordedBase_FailsOnItsScopedTestAlone because its claim names the parent's branch, which holds HEAD" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item unreadable-item '{"test":[]}' committed
item_no_adapter_holds=local:task/999
(cd "$worktree" && "$plugin/scripts/verify.sh" "$item_no_adapter_holds" >/dev/null 2> "$work/unreadable-item.err")
check "ItemItsAdapterCannotRead_PrintsNoStateGuardLine because a failed read has no state for the guard to refuse" \
  '! grep -qF "asked of an item read from its adapter alone" "$work/unreadable-item.err"'
exit "$((fails > 0))"
