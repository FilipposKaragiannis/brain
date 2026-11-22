#!/bin/sh
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

new_item comparison ""
git -C "$worktree" branch original-base
mkdir -p "$worktree/.standards" "$worktree/source"
cat > "$worktree/.standards/config.json" <<'JSON'
{"test":[{"name":"comparison","command":"git diff --quiet {verify_base} HEAD -- source/file","paths":["source/**"]}]}
JSON
echo first > "$worktree/source/file"
git -C "$worktree" add .standards/config.json source/file && git -C "$worktree" commit -qm first
git -C "$worktree" branch second-base
echo other > "$worktree/source/other"
git -C "$worktree" add source/other && git -C "$worktree" commit -qm other

verify --base second-base >/dev/null
same_result=$?
check "ComparisonAgainstMatchingSource_Passes because the command compares the requested base" \
  '[ "$same_result" -eq 0 ]'
verify --base original-base >/dev/null
different_result=$?
check "ComparisonAgainstDifferentSource_Fails because a pass from the other base cannot prove this comparison" \
  '[ "$different_result" -eq 1 ] && [ "$(report_status)" = fail ]'

check_field() { python3 -c 'import json,sys; found=[check for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]]; print(found[0].get(sys.argv[3], "") if found else "no such check")' "$reports/verify.json" "$1" "$2"; }
feel_test() { json_value feel_test < "$reports/verify.json"; }
new_item unresolved ""
mkdir -p "$worktree/.standards" "$worktree/source"
cat > "$worktree/.standards/config.json" <<'JSON'
{"test":[{"name":"received","command":"echo {verify_base}","paths":["source/**"]}]}
JSON
echo first > "$worktree/source/file"
git -C "$worktree" add .standards/config.json source/file && git -C "$worktree" commit -qm first
verify >/dev/null
verify --base no-such-base >/dev/null
unresolved_result=$?
check "UnresolvedBase_RunsTheCheckWithPaths because an unknown change list cannot show that nothing under its paths changed" \
  '[ "$(check_field "tests received" status)" = pass ]'
check "UnresolvedBase_ExitsFailing because a run that cannot list every changed file cannot prove the change" \
  '[ "$unresolved_result" -eq 1 ]'
check "UnresolvedBase_ReportsFail because the report reader must not read an unproven change as green" \
  '[ "$(report_status)" = fail ]'
check "UnresolvedBase_NamesTheBaseInTheFailedCheck because the reader must know what to fix" \
  'check_field "changed files" summary | grep -q "comparison base no-such-base cannot be resolved"'
check "UnresolvedBase_GivesTheCommandUnavailable because the command must know it cannot narrow its run" \
  '[ "$(check_field "tests received" command)" = "echo unavailable" ]'
check "UnresolvedBase_ReusesNoPassFromAResolvedBase because that pass proved a narrower comparison" \
  '[ -z "$(check_field "tests received" reused_from)" ]'
check "UnresolvedBase_ShowsTheComparisonUnavailableInTheReport because a reader of verify.md must see what the change was compared with" \
  'grep -q "(unavailable)" "$reports/verify.md"'
check "UnresolvedBase_NamesTheBaseInTheLog because a reader of the log must see which base could not be resolved" \
  'grep -q "no-such-base cannot be resolved" "$reports/verify.log"'
check "UnresolvedBaseWithNoFeelTestPaths_HasNoFeelTest because no change can fall under paths that do not exist" \
  '[ "$(feel_test)" = false ]'

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
git_fatal_exit=128
real_git="$(command -v git)"; stand_in_git="$work/stand-in-git"; mkdir -p "$stand_in_git"
cat > "$stand_in_git/git" <<'STUB'
#!/bin/sh
case "$*" in
  # shellcheck disable=SC2254 # the pattern is a glob
  $FAILING_GIT_ARGUMENTS) printf '%s' "${FAILING_GIT_OUTPUT:-}"; echo "fatal: stand-in failure of git $*" >&2; exit "$FAILING_GIT_EXIT" ;;
esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$stand_in_git/git"
verify_with_failing_git() {
  # shellcheck disable=SC2154 # new_item in the fixture sets item
  (cd "$worktree" && env FAILING_GIT_ARGUMENTS="$1" FAILING_GIT_OUTPUT="${2:-}" FAILING_GIT_EXIT="$git_fatal_exit" REAL_GIT="$real_git" \
    PATH="$stand_in_git:$PATH" "$plugin/scripts/verify.sh" "$item" >/dev/null 2>&1)
}
base_diff_arguments='diff --no-renames --name-only -z * HEAD --'
uncommitted_diff_arguments='diff --no-renames --name-only -z HEAD --'
untracked_listing_arguments='ls-files --others --exclude-standard -z'
failed_listing_checks() {
  failed_listing_scenario="$1"
  # shellcheck disable=SC2034 # the check's condition reads it
  failed_listing_exit="$4"
  printf '%s failed\n' "$2" > "$work/expected-operation"
  printf 'stand-in failure of git %s\n' "$3" > "$work/expected-git-error"
  check "${failed_listing_scenario}_ExitsFailing because a short change list cannot prove the change" \
    '[ "$failed_listing_exit" -eq 1 ]'
  check "${failed_listing_scenario}_ReportsFail because the report reader must not read an unproven change as green" \
    '[ "$(report_status)" = fail ]'
  check "${failed_listing_scenario}_NamesTheOperation because the reader must know which listing failed" \
    'check_field "changed files" summary | grep -qF -f "$work/expected-operation"'
  check "${failed_listing_scenario}_RunsTheScopedTest because no listing can show nothing under its paths changed" \
    '[ "$(check_field "tests scoped" status)" = fail ]'
  check "${failed_listing_scenario}_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
    '[ "$(feel_test)" = true ]'
  check "${failed_listing_scenario}_KeepsGitsErrorInTheLog because the cause must be readable" \
    'grep -qF -f "$work/expected-git-error" "$reports/verify.log"'
}
failing_scoped_test='{"test":[{"name":"scoped","command":"false","paths":["source/**"]}]}'

changed_source_item git-failure "$failing_scoped_test" committed
verify >/dev/null 2>&1
check "HealthyListWithFailingScopedTest_FailsOnThatTestAlone because a complete change list adds no failed check" \
  '[ "$(failed_checks)" = "tests scoped" ]'
check "HealthyListOutsideFeelTestPaths_HasNoFeelTest because feel_test follows feel_test_paths" \
  '[ "$(feel_test)" = false ]'

verify_with_failing_git "$base_diff_arguments"; base_diff_result=$?
failed_listing_checks BaseDiffFails "the diff from the base main" "diff" "$base_diff_result"

changed_source_item uncommitted-failure "$failing_scoped_test" staged
verify_with_failing_git "$uncommitted_diff_arguments"; uncommitted_diff_result=$?
failed_listing_checks UncommittedDiffFails "the diff of uncommitted changes" "diff" "$uncommitted_diff_result"

changed_source_item untracked-failure "$failing_scoped_test" untracked
verify_with_failing_git "$untracked_listing_arguments"; untracked_listing_result=$?
failed_listing_checks UntrackedListingFails "the listing of untracked files" "ls-files" "$untracked_listing_result"

changed_source_item half-name '{"test":[]}' staged
verify_with_failing_git "$base_diff_arguments" source/half
listed_changed_files() { python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["changed_files"]))' "$reports/verify.json"; }
check "BaseDiffFailsMidName_ListsOnlyWholeNames because a cut name joined to the next listing's first name is a file that does not exist" \
  '[ "$(listed_changed_files)" = source/file.sh ]'

# shellcheck disable=SC2034 # the check's condition reads it
verify_failed_exit=1
real_python="$(command -v python3)"; stand_in_python="$work/stand-in-python"; mkdir -p "$stand_in_python" "$work/no-git"
cat > "$stand_in_python/python3" <<'STUB'
#!/bin/sh
case "$*" in
  *_change_list.py*) exec env PATH="$PATH_WITHOUT_GIT" "$REAL_PYTHON" "$@" ;;
esac
exec "$REAL_PYTHON" "$@"
STUB
chmod +x "$stand_in_python/python3"
changed_source_item git-cannot-start '{"test":[]}' committed
(cd "$worktree" && env PATH_WITHOUT_GIT="$work/no-git" REAL_PYTHON="$real_python" PATH="$stand_in_python:$PATH" \
  "$plugin/scripts/verify.sh" "$item" >/dev/null 2>&1)
# shellcheck disable=SC2034 # the check's condition reads it
git_cannot_start_result=$?
check "GitCannotStart_ExitsFailing because a change list git never produced cannot prove the change" \
  '[ "$git_cannot_start_result" -eq "$verify_failed_exit" ]'
check "GitCannotStart_NamesTheListing because the reader must know which listing could not run" \
  'check_field "changed files" summary | grep -qF "the diff from the base main failed ("'

changed_source_item unreadable-and-failed '{"test":[]}' committed
echo change > "$worktree/unit$(printf '\037')separator.name"
verify_with_failing_git "$base_diff_arguments"
changed_files_checks() { python3 -c 'import json,sys; print(sum(1 for check in json.load(open(sys.argv[1]))["checks"] if check["name"]=="changed files"))' "$reports/verify.json"; }
check "UnreadableNameWithFailedListing_RecordsOneChangedFilesCheck because a reader looks the check up by its name" \
  '[ "$(changed_files_checks)" -eq 1 ]'
check "UnreadableNameWithFailedListing_NamesTheUnreadableName because each cause needs its own fix" \
  'check_field "changed files" summary | grep -q "U+001F"'

changed_source_item healthy-feel '{"test":[]}' committed
mkdir -p "$worktree/ui" && echo change > "$worktree/ui/screen" && git -C "$worktree" add ui/screen && git -C "$worktree" commit -qm "ui change"
verify >/dev/null 2>&1
check "HealthyListWithChangeUnderFeelTestPaths_RaisesFeelTest because feel_test follows feel_test_paths" \
  '[ "$(feel_test)" = true ]'
check "HealthyListWithChangeUnderFeelTestPaths_FailsNoCheck because a complete change list is no failure" \
  '[ -z "$(failed_checks)" ]'

changed_source_item file-named-head '{"test":[]}' committed
echo change > "$worktree/HEAD" && git -C "$worktree" add -- HEAD && git -C "$worktree" commit -qm "a file named HEAD"
verify >/dev/null 2>&1
check "CommittedFileNamedHeadAtTheRoot_FailsNoCheck because git reads HEAD before the -- as the revision, not as the file" \
  '[ -z "$(failed_checks)" ]'

new_item healthy-feel-glob ""
printf 'feel_test_paths:\n  - ui/src/**/*.tsx\n' >> .flow/config.yaml; printf 'button.tsx\n' >> .git/info/exclude
mkdir -p "$worktree/ui/src/widgets" && echo unchanged > "$worktree/ui/src/widgets/button.tsx"
echo change > "$worktree/ui/src/App.tsx" && git -C "$worktree" add ui/src/App.tsx && git -C "$worktree" commit -qm "ui change"
verify >/dev/null 2>&1
check "ChangeMatchingAFeelTestGlobThatAlsoNamesAnUnchangedFile_RaisesFeelTest because the glob is matched against the change, not the folder" \
  '[ "$(feel_test)" = true ]'

changed_source_item git-failure-reuse '{"test":[{"name":"scoped","command":"true","paths":["source/**"]}]}' committed
verify >/dev/null 2>&1
verify >/dev/null 2>&1
check "HealthyListAfterAPass_ReusesThePass because a no-reuse check proves nothing unless a kept pass was there to reuse" \
  '[ -n "$(check_field "tests scoped" reused_from)" ]'
verify_with_failing_git "$base_diff_arguments"
check "BaseDiffFailsAfterAPass_RunsThePassingScopedTest because an unknown change list cannot skip a test with paths" \
  '[ "$(check_field "tests scoped" status)" = pass ]'
check "BaseDiffFailsAfterAPass_ReusesNoPass because a kept pass proved a change list that is now unknown" \
  '[ -z "$(check_field "tests scoped" reused_from)" ]'
echo change > "$worktree/unit$(printf '\037')separator.name"
verify >/dev/null 2>&1
check "UnreadableNameAfterAPass_RunsThePassingScopedTest because a list verify cannot read cannot show nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = pass ]'
check "UnreadableNameAfterAPass_ReusesNoPass because a kept pass proved a change list that verify cannot read now" \
  '[ -z "$(check_field "tests scoped" reused_from)" ]'
check "UnreadableNameAfterAPass_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item unresolved-format '{"test":[],"languages":[{"name":"shell","extensions":[".sh"],"format":[{"prefix":"","command":"false"}]}]}' staged
verify --base no-such-base >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
failing_format_result=$?
check "UnresolvedBaseWithFailingFormat_ExitsFailing because an unresolved base fails the run whatever the formatter says" \
  '[ "$failing_format_result" -eq 1 ]'
check "UnresolvedBaseWithFailingFormat_ReportsFail because the report must not read an unproven change as green" \
  '[ "$(report_status)" = fail ]'
check "UnresolvedBaseWithFailingFormat_FailsTheFormatCheck because a source file changed and not committed is listed without the base, so the formatter runs on it" \
  'failed_checks | tr "," "\n" | grep -qxF format'
check "UnresolvedBaseWithFailingFormat_NamesTheBase because the reader must know what to fix" \
  'check_field "changed files" summary | grep -q "comparison base no-such-base cannot be resolved"'

changed_source_item unresolved-clean '{"test":[]}' committed
verify --base no-such-base >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
clean_unresolved_result=$?
check "UnresolvedBaseWithNothingElseWrong_ExitsFailing because nothing proves the change list" \
  '[ "$clean_unresolved_result" -eq 1 ]'
check "UnresolvedBaseWithNothingElseWrong_FailsOnTheChangedFilesCheckAlone because the unknown list is the only fault" \
  '[ "$(failed_checks)" = "changed files" ]'
check "UnresolvedBaseWithNothingElseWrong_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'
check "UnresolvedBaseWithNothingElseWrong_SaysWhyTheFeelTestIsNeeded because a reader must not look for a matching file" \
  'grep -q "cannot be ruled out" "$reports/verify.md"'

changed_source_item own-branch-claim "$failing_scoped_test" committed
item_branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
set_claim_base "$item" "$item_branch"
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_claim_result=$?
printf "the comparison base %s is the item's own branch\n" "$item_branch" > "$work/expected-own-branch"
check "ClaimBaseRewrittenToTheItemsOwnBranch_ExitsFailing because a base that hides every committed change cannot prove the change" \
  '[ "$own_branch_claim_result" -eq 1 ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_ReportsFail because the report reader must not read a hidden change as green" \
  '[ "$(report_status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_NamesTheOwnBranch because the reader must know why the base is refused" \
  'check_field "changed files" summary | grep -qF -f "$work/expected-own-branch"'
check "ClaimBaseRewrittenToTheItemsOwnBranch_RunsTheScopedTest because a hiding base cannot show that nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = fail ]'
check "ClaimBaseRewrittenToTheItemsOwnBranch_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'

changed_source_item claim-disagrees '{"test":[]}' committed
git -C "$worktree" branch elsewhere main
set_claim_base "$item" elsewhere
verify >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
claim_disagrees_result=$?
printf "the claim names the base elsewhere, the item's record names main\n" > "$work/expected-disagreement"
check "ClaimBaseDiffersFromTheItemsRecord_ExitsFailing because verify cannot tell which of the two bases is the item's" \
  '[ "$claim_disagrees_result" -eq 1 ]'
check "ClaimBaseDiffersFromTheItemsRecord_NamesBothBases because the reader must see the two names to fix the claim" \
  'check_field "changed files" summary | grep -qF -f "$work/expected-disagreement"'

changed_source_item own-branch-option '{"test":[]}' committed
verify --base "$(git -C "$worktree" symbolic-ref --short HEAD)" >/dev/null 2>&1
# shellcheck disable=SC2034 # the check's condition reads it
own_branch_option_result=$?
check "BaseOptionNamingTheItemsOwnBranch_ExitsFailing because the caller's choice of base still cannot hide the committed change" \
  '[ "$own_branch_option_result" -eq 1 ]'
check "BaseOptionNamingTheItemsOwnBranch_FailsOnTheChangedFilesCheckAlone because the refused base is the only fault" \
  '[ "$(failed_checks)" = "changed files" ]'

changed_source_item no-commits-yet "$failing_scoped_test" staged
git -C "$worktree" reset -q --soft main
verify >/dev/null 2>&1
check "ItemWithNoCommitsYet_FailsOnItsScopedTestAlone because a base at HEAD hides nothing when the branch holds no commit of its own" \
  '[ "$(failed_checks)" = "tests scoped" ]'

changed_source_item no-recorded-base "$failing_scoped_test" committed
"$local_adapter/write-state.sh" "$item" base= >/dev/null
rm -f "$worktree/.flow/claim.json"
verify >/dev/null 2>&1
check "NoClaimAndNoRecordedBase_FailsOnItsScopedTestAlone because the config base is the base of an item nothing records one for" \
  '[ "$(failed_checks)" = "tests scoped" ]'

new_item slice-parent ""
slice_parent="$item"
# shellcheck disable=SC2034 # the check's condition reads it
slice_parent_branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
item="$("$local_adapter/create.sh" task "Slice child" --size S --body x --parent "$slice_parent")"
"$plugin/scripts/next.sh" "$item" >/dev/null 2>&1
worktree="$("$plugin/scripts/steward.sh" find "$item")"; reports="$worktree/.flow/reports/$(slug "$item")"
mkdir -p "$worktree/.standards" "$worktree/source"
printf '%s\n' "$failing_scoped_test" > "$worktree/.standards/config.json"
echo change > "$worktree/source/file.sh"
git -C "$worktree" add .standards/config.json source/file.sh && git -C "$worktree" commit -qm "slice change"
verify >/dev/null 2>&1
check "EpicSliceOnItsParentsBranch_ComparesWithTheParentsBranch because the slice merges into its parent's branch" \
  '[ "$(json_value base < "$reports/verify.json")" = "$slice_parent_branch" ]'
check "EpicSliceOnItsParentsBranch_FailsOnItsScopedTestAlone because the parent's branch is the slice's recorded base" \
  '[ "$(failed_checks)" = "tests scoped" ]'
exit "$((fails > 0))"
