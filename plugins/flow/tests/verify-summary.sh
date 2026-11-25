#!/bin/sh
# verify-summary.sh: each verify check shows a summary line beside its result: the last output line
# its `summary` pattern matches (a gate's map, or verify.summary in the flow config for build, test
# and mutation), else its last non-empty output line, and a failed check keeps the tail of its
# output. On the local adapter in throwaway repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

check_summary() { python3 -c 'import json,sys; print([check["summary"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]][0])' "$reports/verify.json" "$1"; }
summary_without_output="$(python3 -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import _verify_report; print(_verify_report.SUMMARY_WITHOUT_OUTPUT)' "$plugin/scripts")"
broken_pattern='\d+ (passed'
markdown_row() { grep -F "| $1 | $2 |" "$reports/verify.md"; }
printing_script() {
  printing_script_path="$work/$1.sh"; printing_script_exit="$2"; shift 2
  { echo '#!/bin/sh'; for printing_script_line in "$@"; do printf 'printf "%%b\\n" %s\n' "'$printing_script_line'"; done; echo "exit $printing_script_exit"; } > "$printing_script_path"
  printf '%s' "$printing_script_path"
}

counted="$(printing_script counted 0 'collecting' '3 passed, 1 skipped in 0.4s' 'teardown done')"
plain="$(printing_script plain 0 'first line' 'last line' '' '   ')"
coloured="$(printing_script coloured 0 '\033[32m5 passed\033[0m' 'teardown done')"
unmatched="$(printing_script unmatched 0 'only line')"
broken="$(printing_script broken 0 'any line')"
failing="$(printing_script failing 1 'cause one' 'cause two' 'last failure line' '')"
echo "gates with and without a summary pattern"
new_item gates "  counted:
    command: 'sh $counted'
    summary: '\\d+ passed'
  plain: 'sh $plain'
  coloured:
    command: 'sh $coloured'
    summary: '^\\d+ passed'
  unmatched:
    command: 'sh $unmatched'
    summary: 'never printed'
  silent: 'true'
  broken:
    command: 'sh $broken'
    summary: '$broken_pattern'
  failing: 'sh $failing'"
verify >/dev/null 2>&1
check "GateWithSummaryPattern_SummaryIsTheMatchingLine: a reviewer sees what the check proved without opening the log" \
  '[ "$(check_summary "gate counted")" = "3 passed, 1 skipped in 0.4s" ]'
check "GateWithSummaryPattern_MarkdownShowsTheMatchingLineBesideItsResult: the report row carries the line next to pass" \
  'markdown_row "gate counted" pass | grep -qF "| 3 passed, 1 skipped in 0.4s |"'
check "GateWithNoSummaryPattern_SummaryIsItsLastNonEmptyLine: with no setup the default still beats a bare ok" \
  '[ "$(check_summary "gate plain")" = "last line" ]'
check "GateWithNoSummaryPattern_MarkdownShowsItsLastNonEmptyLineBesideItsResult: the report row carries the line next to pass" \
  'markdown_row "gate plain" pass | grep -qF "| last line |"'
check "ColouredOutput_PatternMatchesTheLineWithoutItsColours: a runner that colours its counts still gets its line picked" \
  '[ "$(check_summary "gate coloured")" = "5 passed" ]'
check "PatternThatMatchesNoLine_SummaryIsTheLastNonEmptyLine: a pattern that misses falls back to the default, never to nothing" \
  '[ "$(check_summary "gate unmatched")" = "only line" ]'
check "PassWithNoOutput_SummaryIsTheBuildersNoOutputWord: a silent pass still shows a result" \
  '[ -n "$summary_without_output" ] && [ "$(check_summary "gate silent")" = "$summary_without_output" ]'
check "PatternThatIsNoRegularExpression_SummaryNamesThePattern: a broken pattern is a config fault the owner can see and fix" \
  'check_summary "gate broken" | grep -qF -- "$broken_pattern"'
check "FailedGateWithNoSummaryPattern_SummaryEndsWithItsLastNonEmptyLine: the default line shows on a fail as on a pass" \
  'check_summary "gate failing" | grep -q "last failure line\$"'
check "FailedGate_SummaryKeepsTheTailOfItsOutput: the stop gate and the escalation read the cause from it" \
  'check_summary "gate failing" | grep -qF "cause one cause two last failure line"'

echo "build, test and mutation with patterns under verify.summary"
build_script="$(printing_script build 0 'compiling 12 files' 'built 12 files' 'cleanup')"
test_script="$(printing_script tests 0 'collected 4 items' '4 passed in 0.1s' 'bye')"
mutation_script="$(printing_script mutation 1 'mutating' 'score 80%' 'some mutants survived')"
limit_yaml="verify:
  summary:
    build: '^built'
    test: '\\d+ passed in'
    mutation: '^score'
"
new_item kinds "  ok: 'true'"
limit_yaml=""
mkdir -p "$worktree/.standards"
printf '{"build": "sh %s", "test": "sh %s", "mutation": "sh %s"}\n' "$build_script" "$test_script" "$mutation_script" > "$worktree/.standards/config.json"
git -C "$worktree" add -A && git -C "$worktree" commit -qm standards
verify >/dev/null 2>&1
check "BuildWithSummaryPattern_SummaryIsTheMatchingLine: verify.summary.build picks the build's line" \
  '[ "$(check_summary build)" = "built 12 files" ]'
check "TestWithSummaryPattern_SummaryIsTheMatchingLine: verify.summary.test picks the test counts" \
  '[ "$(check_summary tests)" = "4 passed in 0.1s" ]'
check "MutationSignalWithSummaryPattern_SummaryIsTheMatchingLine: verify.summary.mutation picks the score of a run that is a signal" \
  '[ "$(check_summary mutation)" = "score 80%" ]'

if [ "$fails" -eq 0 ]; then echo "verify-summary: ok"; else echo "verify-summary: $fails failed"; exit 1; fi
