#!/bin/sh
# verify-pr-body.sh: pr-report.sh renders the verify report as the Verification section of a pull
# request body: the heading, the verdict and the count, one proofs row per acceptance line (a live
# proof names its file and links nothing, a test proof names its test), the Not checked list and no
# checks table; a folder with no report or a report without a key the section needs stops it with
# the reason. The reports come from the real verify, on the local adapter in throwaway repos, from
# a proofs file the suite writes. Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

section_heading="## Verification"
first_section_lines=4
count_line_number=2
rendered_exit=0
missing_report_exit=1
test_name=Greet_WithName_PrintsHello
build_only_reason="the Unity client has no capture command yet"
blocked_reason="the staging server is down"
not_checked_title="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from _pr_report import NOT_CHECKED_TITLE; print(NOT_CHECKED_TITLE)' "$plugin/scripts")"
not_checked_none="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from _verify_report import NOT_CHECKED_NONE; print(NOT_CHECKED_NONE)' "$plugin/scripts")"
# capture_gate <name>: a gate that runs capture-<name>.sh from the work folder, which
# write_capture writes once new_item has named the reports folder.
capture_gate() { printf "  capture: 'sh %s/capture-%s.sh'\n" "$work" "$1"; }
write_capture() { printf '%s\n' "$2" > "$work/capture-$1.sh"; }
commit_test_command() {
  mkdir -p "$worktree/.standards" && printf '{"test": "%s"}\n' "$1" > "$worktree/.standards/config.json"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "test command"
}
# write_proofs <proofs list>: proofs.json for the worktree's head, as the verifier writes it.
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
report_value() { json_value "$1" < "$reports/verify.json"; }
# render <reports> <name>: pr-report.sh on the folder; stdout in <name>.out, stderr in <name>.err
# and the exit code in <name>.code under the work folder.
render() { "$plugin/scripts/pr-report.sh" "$1" > "$work/$2.out" 2> "$work/$2.err"; echo "$?" > "$work/$2.code"; }
rendered() { cat "$work/$1.out"; }
render_code() { cat "$work/$1.code"; }
section_row() { awk -v line="$2" 'index($0, "| " line " |") == 1' "$work/$1.out"; }
section_row_lines() { awk -F '|' '/^\| [0-9?]/ { gsub(/ /, "", $2); print $2 }' "$work/$1.out"; }
section_not_checked() { awk -v title="$not_checked_title" '$0 == title { listed = 1; next } listed && $0 == "" { exit } listed' "$work/$1.out"; }
json_proof_lines() { python3 -c 'import json,sys; print("\n".join(str(proof["line"]) for proof in json.load(open(sys.argv[1]))["proofs"]))' "$reports/verify.json"; }
first_lines_expected() { printf '%s\n\n%s\n%s\n' "$section_heading" "$(report_value verdict)" "$(sed -n "${count_line_number}p" "$reports/verify.md")"; }

echo "one proof of each grade, all holding"
new_item every-grade "$(capture_gate every-grade)"
write_capture every-grade "mkdir -p '$reports/evidence' && echo png > '$reports/evidence/login-error.png'"
commit_test_command true
write_proofs "[{\"line\": 1, \"text\": \"greet prints hello\", \"grade\": \"test\", \"test\": \"$test_name\"},
  {\"line\": 2, \"text\": \"the login error shows\", \"grade\": \"live\", \"evidence\": \"evidence/login-error.png\"},
  {\"line\": 3, \"text\": \"the client renders\", \"grade\": \"build-only\", \"reason\": \"$build_only_reason\"},
  {\"line\": 4, \"text\": \"the staging deploy works\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
verify >/dev/null 2>&1
every_grade_reports="$reports"
render "$every_grade_reports" every-grade
check "Render_PassingReport_FirstLinesAreHeadingVerdictAndCount: the section opens with its heading, then verify's own verdict and count" \
  '[ "$(render_code every-grade)" = "$rendered_exit" ] && [ "$(rendered every-grade | head -n "$first_section_lines")" = "$(first_lines_expected)" ]'
check "Render_ReportWithProofs_HasOneRowPerAcceptanceLine: a reviewer sees each graded line once" \
  '[ -n "$(json_proof_lines)" ] && [ "$(section_row_lines every-grade)" = "$(json_proof_lines)" ]'
check "Render_LiveProof_NamesTheFileWithoutALink: a link relative to the reports folder resolves in no pull request" \
  'section_row every-grade 2 | grep -qF "\`login-error.png\`" && ! section_row every-grade 2 | grep -qF "]("'
check "Render_TestProof_NamesTheTest: a reviewer finds the test that proves the line" \
  'section_row every-grade 1 | grep -qF "\`$test_name\`"'
check "Render_BuildOnlyAndBlockedLines_ListedUnderNotChecked: a reviewer sees what was left out and why" \
  '[ "$(section_not_checked every-grade | tr "\n" "|")" = "- Line 3, build-only: $build_only_reason.|- Line 4, blocked: $blocked_reason.|" ]'
check "Render_Report_CarriesNoChecksTable: the checks stay in the full report in the reports folder" \
  'grep -q "^## Checks" "$every_grade_reports/verify.md" && [ -n "$(rendered every-grade)" ] && ! rendered every-grade | grep -qE "^## Checks|^\\| check \\|"'

echo "every line proven"
new_item all-proven "  ok: 'true'"
commit_test_command true
write_proofs "[{\"line\": 1, \"text\": \"greet prints hello\", \"grade\": \"test\", \"test\": \"$test_name\"}]"
verify >/dev/null 2>&1
render "$reports" all-proven
check "Render_NothingUnchecked_NotCheckedSaysNone: an empty list still says so, as verify's report does" \
  '[ -n "$not_checked_none" ] && [ "$(section_not_checked all-proven)" = "$not_checked_none" ]'

echo "a folder with no report"
mkdir -p "$work/no-report"
render "$work/no-report" no-report
check "Render_NoVerifyJson_ExitsOneAndNamesTheFolder: the pr-creator stops and the owner learns which folder holds no report" \
  '[ "$(render_code no-report)" = "$missing_report_exit" ] && grep -qF "$work/no-report" "$work/no-report.err"'

echo "a report of an older shape"
mkdir -p "$work/old-shape"
python3 -c 'import json,sys; report=json.load(open(sys.argv[1])); del report["proofs"]; json.dump(report, open(sys.argv[2], "w"))' \
  "$every_grade_reports/verify.json" "$work/old-shape/verify.json"
render "$work/old-shape" old-shape
check "Render_ReportWithoutProofsKey_ExitsOneAndNamesTheKey: a report verify wrote before proofs fails fast, naming what it lacks" \
  '[ "$(render_code old-shape)" = "$missing_report_exit" ] && grep -qF "proofs" "$work/old-shape.err"'

if [ "$fails" -eq 0 ]; then echo "verify-pr-body: ok"; else echo "verify-pr-body: $fails failed"; exit 1; fi
