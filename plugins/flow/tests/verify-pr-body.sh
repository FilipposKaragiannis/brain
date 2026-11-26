#!/bin/sh
# verify-pr-body.sh: pr-report.sh renders the verify report as the Verification section of a pull
# request body: the heading, the verdict and the count, one proofs row per acceptance line (a live
# proof names its file and links nothing, a test proof names its test), the Not checked list and no
# checks table; a folder with no report or a report without a key the section needs stops it with
# the reason. Each text capture under evidence/, nested or not, shows its last lines in a collapsed
# block with a fence no backtick run closes and no control character, a live proof of it points
# there, and the excerpts stop at the budget; an image shows none, a binary file is only named, and
# a link is never read. The reports come from the real verify, on the local adapter in throwaway
# repos, from a proofs file and captures the suite writes. Exit 0 when every check passes, 1 on any failure. run.sh runs it.
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
pr_report_constant() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_report; print(getattr(_pr_report, sys.argv[2]))' "$plugin/scripts" "$1"; }
excerpt_lines_kept="$(pr_report_constant EXCERPT_LINES)"
excerpt_line_characters="$(pr_report_constant EXCERPT_LINE_CHARACTERS)"
excerpt_budget="$(pr_report_constant EXCERPT_BUDGET_CHARACTERS)"
summary_line="$(pr_report_constant SUMMARY_LINE)"
summary_after_name="${summary_line#*%s}"
summary_before_name="${summary_line%%%s*}"; summary_after_name="${summary_after_name%%, %s*}"
details_open="$(pr_report_constant DETAILS_OPEN)"
details_close="$(pr_report_constant DETAILS_CLOSE)"
excerpt_below="$(pr_report_constant EXCERPT_BELOW)"
body_full="$(pr_report_constant BODY_FULL)"
kept_line="$(pr_report_constant KEPT_LINE)"
dropped_log_lines=7
long_log_lines=$((excerpt_lines_kept + dropped_log_lines))
backtick_run_length=5
backtick_run="$(printf "%${backtick_run_length}s" "" | tr " " "\`")"
notes_marker="the login page greeted the owner"
nested_marker="the nested step finished"
outside_marker="a secret kept outside the evidence folder"
files_past_budget=1
line_break_characters=1
first_budget_file=1
login_proof_line=1
budget_file_characters=$((excerpt_lines_kept * (excerpt_line_characters + line_break_characters)))
budget_files=$((excerpt_budget / budget_file_characters + files_past_budget))
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
# excerpt_block <name> <file>: the collapsed block whose summary names the file, to its closing tag.
excerpt_block() {
  awk -v summary="$summary_before_name$2$summary_after_name" -v closing_tag="$details_close" \
    'index($0, summary) == 1 { shown = 1 } shown { print } shown && $0 == closing_tag { exit }' "$work/$1.out"
}
line_before_summary() { awk -v summary="$summary_before_name$2$summary_after_name" 'index($0, summary) == 1 { print previous; exit } { previous = $0 }' "$work/$1.out"; }
excerpt_fence() { excerpt_block "$1" "$2" | awk '/^```/ { sub(/[a-z]+$/, ""); print; exit }'; }
excerpt_lines() { excerpt_block "$1" "$2" | awk 'fence == "" && /^```/ { fence = $0; sub(/[a-z]+$/, "", fence); next } fence != "" && $0 == fence { exit } fence != ""'; }
long_log_tail() { seq "$long_log_lines" | tail -n "$excerpt_lines_kept" | sed 's/^/log line /'; }
fence_length() { fence_length_fence="$(excerpt_fence "$1" "$2")"; echo "${#fence_length_fence}"; }
kept_line_of() { printf '%s`%s`%s\n' "${kept_line%%%s*}" "$1" "${kept_line#*%s}"; }
budget_file_name() { printf "budget-%0${#budget_files}d.log" "$1"; }
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

echo "text, media, binary, nested and linked captures"
new_item excerpts "$(capture_gate excerpts)"
{ printf "evidence='%s/evidence'\noutside='%s/outside-secret.txt'\nlong_log_lines=%s\nbacktick_run='%s'\n" \
    "$reports" "$work" "$long_log_lines" "$backtick_run"
  printf "notes_marker='%s'\nnested_marker='%s'\noutside_marker='%s'\n" "$notes_marker" "$nested_marker" "$outside_marker"
  cat <<'CAPTURE'
mkdir -p "$evidence/nested"
awk -v lines="$long_log_lines" 'BEGIN { for (line = 1; line <= lines; line++) print "log line " line }' > "$evidence/login.log"
printf '%s\n' "$notes_marker" > "$evidence/notes.txt"
printf 'before %s after\n' "$backtick_run" > "$evidence/ticks.txt"
printf 'plain \033[31mred\033[0m \033]8;;https://example.invalid/hidden\033\\link\033]8;;\033\\ bell\007 return\r\n' > "$evidence/colours.log"
printf 'not really a png\n' > "$evidence/screen.png"
printf 'core\000dump\n' > "$evidence/core.bin"
printf '%s\n' "$nested_marker" > "$evidence/nested/step.log"
printf '%s\n' "$outside_marker" > "$outside"
ln -s "$outside" "$evidence/linked.log"
CAPTURE
} > "$work/capture-excerpts.sh"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login log shows the greeting", "grade": "live", "evidence": "evidence/login.log"}]'
verify >/dev/null 2>&1
render "$reports" excerpts
check "Render_TextEvidence_ShowsInACollapsedBlock: a reviewer reads the capture in the pull request without it filling the page" \
  '[ -n "$details_open" ] && [ "$(line_before_summary excerpts notes.txt)" = "$details_open" ] && excerpt_lines excerpts notes.txt | grep -qxF "$notes_marker"'
check "Render_LongLog_KeepsOnlyTheLastLines: the end of a log holds the outcome, and the body stays short" \
  '[ -n "$(excerpt_lines excerpts login.log)" ] && [ "$(excerpt_lines excerpts login.log)" = "$(long_log_tail)" ]'
check "Render_EvidenceWithBackticks_FenceIsLongerThanAnyRun: a capture that holds a fence cannot close the block early" \
  'excerpt_lines excerpts ticks.txt | grep -qF "$backtick_run" && [ "$(fence_length excerpts ticks.txt)" -gt "$backtick_run_length" ]'
check "Render_ImageEvidence_HasNoExcerpt: an image is no text, so it shows only where a proof names it" \
  '[ -n "$details_open" ] && rendered excerpts | grep -qF "$details_open" && ! rendered excerpts | grep -qF screen.png'
check "Render_BinaryEvidence_NamedWithoutExcerpt: a reviewer learns the file exists without bytes that render as noise" \
  'rendered excerpts | grep -qxF -e "$(kept_line_of core.bin)" && [ -z "$(excerpt_block excerpts core.bin)" ]'
check "Render_EvidenceWithColours_ExcerptHasNoControlCharacters: terminal codes would show as noise in the pull request" \
  '[ -n "$(excerpt_lines excerpts colours.log)" ] && [ "$(excerpt_lines excerpts colours.log | LC_ALL=C tr -d "\001-\010\013-\037\177")" = "$(excerpt_lines excerpts colours.log)" ]'
check "Render_LiveTextProof_CellPointsToTheExcerpt: a reviewer finds the capture that proves the line below the table" \
  '[ -n "$excerpt_below" ] && section_row excerpts "$login_proof_line" | grep -qF "\`login.log\`$excerpt_below"'
check "Render_NestedTextEvidence_ShowsInACollapsedBlock: a capture may write into a folder of its own" \
  'excerpt_lines excerpts nested/step.log | grep -qxF "$nested_marker"'
check "Render_LinkInEvidenceFolder_HasNoExcerpt: a link could publish a file from outside the evidence folder" \
  '[ -n "$details_open" ] && rendered excerpts | grep -qF "$details_open" && ! rendered excerpts | grep -qF -e "$outside_marker" -e linked.log'

echo "captures past the excerpt budget"
new_item over-budget "$(capture_gate over-budget)"
{ printf "evidence='%s/evidence'\nlines=%s\ncharacters=%s\nbudget_files=%s\n" \
    "$reports" "$excerpt_lines_kept" "$excerpt_line_characters" "$budget_files"
  cat <<'CAPTURE'
mkdir -p "$evidence"
file_number=1
while [ "$file_number" -le "$budget_files" ]; do
  awk -v lines="$lines" -v characters="$characters" 'BEGIN { while (length(row) < characters) row = row "x"; for (line = 1; line <= lines; line++) print row }' \
    > "$evidence/budget-$(printf "%0${#budget_files}d" "$file_number").log"
  file_number=$((file_number + 1))
done
CAPTURE
} > "$work/capture-over-budget.sh"
commit_test_command true
verify >/dev/null 2>&1
render "$reports" over-budget
check "Render_EvidenceOverBudget_LeavesTheExcerptOut: the body stays under GitHub's limit however much the captures hold" \
  '[ -n "$body_full" ] && [ -n "$(excerpt_fence over-budget "$(budget_file_name "$first_budget_file")")" ] && excerpt_block over-budget "$(budget_file_name "$budget_files")" | grep -qxF -e "$body_full" && [ -z "$(excerpt_fence over-budget "$(budget_file_name "$budget_files")")" ]'

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
