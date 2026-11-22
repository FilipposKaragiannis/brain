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
# changed_source_item <dir> <standards json>: an item whose worktree commits the standards and a
# change under source/, with feel_test_paths that name only ui/**.
changed_source_item() {
  new_item "$1" ""
  printf 'feel_test_paths:\n  - ui/**\n' >> .flow/config.yaml
  mkdir -p "$worktree/.standards" "$worktree/source"
  printf '%s\n' "$2" > "$worktree/.standards/config.json"
  echo change > "$worktree/source/file.sh"
  git -C "$worktree" add .standards/config.json source/file.sh && git -C "$worktree" commit -qm "source change"
}
real_git="$(command -v git)"; stand_in_git="$work/stand-in-git"; mkdir -p "$stand_in_git"
cat > "$stand_in_git/git" <<STUB
#!/bin/sh
case "\$*" in
  \$(cat "$work/failing-git-arguments")) echo "fatal: stand-in failure of git \$*" >&2; exit 128 ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$stand_in_git/git"
# verify_with_failing_git <argument pattern>: verify with a git that fails the one call whose
# arguments match the pattern and runs the real git for every other.
verify_with_failing_git() {
  printf '%s\n' "$1" > "$work/failing-git-arguments"
  (PATH="$stand_in_git:$PATH"; export PATH; verify >/dev/null 2>&1); verify_exit_code=$?
}

changed_source_item git-failure '{"test":[{"name":"scoped","command":"false","paths":["source/**"]}]}'
verify >/dev/null 2>&1
check "HealthyListWithFailingScopedTest_FailsOnThatTestAlone because a complete change list adds no failed check" \
  '[ "$(failed_checks)" = "tests scoped" ]'
check "HealthyListOutsideFeelTestPaths_HasNoFeelTest because feel_test follows feel_test_paths" \
  '[ "$(feel_test)" = false ]'

verify_with_failing_git 'diff --no-renames --name-only -z * HEAD'
check "BaseDiffFails_FailsVerify because a short change list cannot prove the change" \
  'verify_exited_failing && [ "$(report_status)" = fail ]'
check "BaseDiffFails_NamesTheOperation because the reader must know which listing failed" \
  'check_field "changed files" summary | grep -q "the diff from the base main failed"'
check "BaseDiffFails_RunsTheScopedTest because no listing can show nothing under its paths changed" \
  '[ "$(check_field "tests scoped" status)" = fail ]'
check "BaseDiffFails_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'
check "BaseDiffFails_KeepsGitsErrorInTheLog because the cause must be readable" \
  'grep -q "stand-in failure of git diff" "$reports/verify.log"'

verify_with_failing_git 'diff --no-renames --name-only -z HEAD'
check "UncommittedDiffFails_FailsVerifyNamingIt because a short change list cannot prove the change" \
  '[ "$(report_status)" = fail ] && check_field "changed files" summary | grep -q "the diff of uncommitted changes failed"'

verify_with_failing_git 'ls-files --others --exclude-standard -z'
check "UntrackedListingFails_FailsVerifyNamingIt because a short change list cannot prove the change" \
  '[ "$(report_status)" = fail ] && check_field "changed files" summary | grep -q "the listing of untracked files failed"'

changed_source_item unresolved-format '{"test":[],"languages":[{"name":"shell","extensions":[".sh"],"format":[{"prefix":"","command":"false"}]}]}'
verify --base no-such-base >/dev/null 2>&1; verify_exit_code=$?
check "UnresolvedBaseWithFailingFormat_FailsVerify because a skipped formatter must not let the run pass" \
  'verify_exited_failing && [ "$(report_status)" = fail ] && [ "$(check_field format status)" != pass ]'
check "UnresolvedBaseWithFailingFormat_NamesTheBase because the reader must know what to fix" \
  'check_field "changed files" summary | grep -q "comparison base no-such-base cannot be resolved"'

changed_source_item unresolved-clean '{"test":[]}'
verify --base no-such-base >/dev/null 2>&1; verify_exit_code=$?
check "UnresolvedBaseWithNothingElseWrong_FailsVerify because nothing proves the change list" \
  'verify_exited_failing && [ "$(failed_checks)" = "changed files" ]'
check "UnresolvedBaseWithNothingElseWrong_RaisesFeelTest because a change under the feel-test paths cannot be ruled out" \
  '[ "$(feel_test)" = true ]'
exit "$((fails > 0))"
