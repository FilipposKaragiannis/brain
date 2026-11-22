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
check "UnresolvedBase_FailsVerify because a run that cannot list every changed file cannot prove the change" \
  '[ "$unresolved_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "UnresolvedBase_NamesTheBaseInTheFailedCheck because the reader must know what to fix" \
  'check_field "changed files" summary | grep -q "comparison base no-such-base cannot be resolved"'
check "UnresolvedBase_GivesTheCommandUnavailable because the command must know it cannot narrow its run" \
  '[ "$(check_field "tests received" command)" = "echo unavailable" ]'
check "UnresolvedBase_ReusesNoPassFromAResolvedBase because that pass proved a narrower comparison" \
  '[ -z "$(check_field "tests received" reused_from)" ]'
check "UnresolvedBase_IsNamedInTheReport because a reader must see the comparison was unavailable" \
  'grep -q "(unavailable)" "$reports/verify.md" && grep -q "no-such-base cannot be resolved" "$reports/verify.log"'

feel_test() { json_value feel_test < "$reports/verify.json"; }
verify_exit_code=0
verify_exited_failing() { [ "$verify_exit_code" -eq 1 ]; }
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
cat > "$stand_in_git/git" <<STUB
#!/bin/sh
case "\$*" in
  \$(cat "$work/failing-git-arguments")) echo "fatal: stand-in failure of git \$*" >&2; exit $git_fatal_exit ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$stand_in_git/git"
verify_with_failing_git() {
  printf '%s\n' "$1" > "$work/failing-git-arguments"
  (PATH="$stand_in_git:$PATH"; export PATH; verify >/dev/null 2>&1); verify_exit_code=$?
}
base_diff_arguments='diff --no-renames --name-only -z * HEAD'
uncommitted_diff_arguments='diff --no-renames --name-only -z HEAD'
untracked_listing_arguments='ls-files --others --exclude-standard -z'
failed_listing_checks() {
  failed_scenario="$1"
  printf '%s failed\n' "$2" > "$work/expected-operation"
  printf 'stand-in failure of git %s\n' "$3" > "$work/expected-git-error"
  check "${failed_scenario}_FailsVerify because a short change list cannot prove the change" \
    'verify_exited_failing && [ "$(report_status)" = fail ]'
  check "${failed_scenario}_NamesTheOperation because the reader must know which listing failed" \
    'check_field "changed files" summary | grep -qF -f "$work/expected-operation"'
  check "${failed_scenario}_RunsTheScopedTest because no listing can show nothing under its paths changed" \
    '[ "$(check_field "tests scoped" status)" = fail ]'
  check "${failed_scenario}_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
    '[ "$(feel_test)" = true ]'
  check "${failed_scenario}_KeepsGitsErrorInTheLog because the cause must be readable" \
    'grep -qF -f "$work/expected-git-error" "$reports/verify.log"'
}
failing_scoped_test='{"test":[{"name":"scoped","command":"false","paths":["source/**"]}]}'

changed_source_item git-failure "$failing_scoped_test" committed
verify >/dev/null 2>&1
check "HealthyListWithFailingScopedTest_FailsOnThatTestAlone because a complete change list adds no failed check" \
  '[ "$(failed_checks)" = "tests scoped" ]'
check "HealthyListOutsideFeelTestPaths_HasNoFeelTest because feel_test follows feel_test_paths" \
  '[ "$(feel_test)" = false ]'

verify_with_failing_git "$base_diff_arguments"
failed_listing_checks BaseDiffFails "the diff from the base main" "diff"

changed_source_item uncommitted-failure "$failing_scoped_test" staged
verify_with_failing_git "$uncommitted_diff_arguments"
failed_listing_checks UncommittedDiffFails "the diff of uncommitted changes" "diff"

changed_source_item untracked-failure "$failing_scoped_test" untracked
verify_with_failing_git "$untracked_listing_arguments"
failed_listing_checks UntrackedListingFails "the listing of untracked files" "ls-files"

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
  '[ "$(feel_test)" = true ] && [ -z "$(failed_checks)" ]'

new_item healthy-feel-glob ""
printf 'feel_test_paths:\n  - ui/src/**/*.tsx\n' >> .flow/config.yaml; printf 'button.tsx\n' >> .git/info/exclude
mkdir -p "$worktree/ui/src/widgets" && echo unchanged > "$worktree/ui/src/widgets/button.tsx"
echo change > "$worktree/ui/src/App.tsx" && git -C "$worktree" add ui/src/App.tsx && git -C "$worktree" commit -qm "ui change"
verify >/dev/null 2>&1
check "ChangeMatchingAFeelTestGlobThatAlsoNamesAnUnchangedFile_RaisesFeelTest because the glob is matched against the change, not the folder" \
  '[ "$(feel_test)" = true ]'

changed_source_item git-failure-reuse '{"test":[{"name":"scoped","command":"true","paths":["source/**"]}]}' committed
verify >/dev/null 2>&1
verify_with_failing_git "$base_diff_arguments"
check "BaseDiffFailsAfterAPass_ReusesNoPass because a kept pass proved a change list that is now unknown" \
  '[ "$(check_field "tests scoped" status)" = pass ] && [ -z "$(check_field "tests scoped" reused_from)" ]'

changed_source_item unresolved-format '{"test":[],"languages":[{"name":"shell","extensions":[".sh"],"format":[{"prefix":"","command":"false"}]}]}' committed
verify --base no-such-base >/dev/null 2>&1; verify_exit_code=$?
check "UnresolvedBaseWithFailingFormat_FailsVerify because a skipped formatter must not let the run pass" \
  'verify_exited_failing && [ "$(report_status)" = fail ]'
check "UnresolvedBaseWithFailingFormat_ShowsNoPassInTheReport because a reader of the report must not read the run as green" \
  'grep -q "^## Verify: fail" "$reports/verify.md" && ! grep -q "^## Verify: pass" "$reports/verify.md"'
check "UnresolvedBaseWithFailingFormat_NamesTheBase because the reader must know what to fix" \
  'check_field "changed files" summary | grep -q "comparison base no-such-base cannot be resolved"'

changed_source_item unresolved-clean '{"test":[]}' committed
verify --base no-such-base >/dev/null 2>&1; verify_exit_code=$?
check "UnresolvedBaseWithNothingElseWrong_FailsVerify because nothing proves the change list" \
  'verify_exited_failing && [ "$(failed_checks)" = "changed files" ]'
check "UnresolvedBaseWithNothingElseWrong_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'
check "UnresolvedBaseWithNothingElseWrong_SaysWhyTheFeelTestIsNeeded because a reader must not look for a matching file" \
  'grep -q "cannot be ruled out" "$reports/verify.md"'
exit "$((fails > 0))"
