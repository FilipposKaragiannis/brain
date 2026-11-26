#!/bin/sh
# verify-proofs.sh: verify grades the proofs file the verifier writes before the run into both
# reports: the count of acceptance lines proven live or by test on the Markdown's second line and
# in the JSON, one graded proof per line in the JSON and in a Proofs table, and the lines graded
# build-only, blocked or error in the Not checked list. A live proof needs a file under evidence/,
# a test proof a test name and a passing tests check, a line number outside the file or used twice
# is an error, a file written for another commit grades no line, and a proofs file that is no JSON
# object never stops the report. Each run's gate writes its evidence, as a capture does, and the
# suite writes proofs.json alone, never a report. On the local adapter in throwaway repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

count_line_number=2
test_name=Greet_WithName_PrintsHello
build_only_reason="the Unity client has no capture command yet"
blocked_reason="the staging server is down"
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
count_line() { sed -n "${count_line_number}p" "$reports/verify.md"; }
proof_rows() { awk -F '|' '/^## / { in_proofs = ($0 == "## Proofs") } in_proofs && /^\| [0-9?]/ { gsub(/ /, "", $2); gsub(/ /, "", $4); print $2 ":" $4 }' "$reports/verify.md"; }
proof_row() { awk -v line="$1" '/^## / { in_proofs = ($0 == "## Proofs") } in_proofs && index($0, "| " line " |") == 1' "$reports/verify.md"; }
json_proof_grades() { python3 -c 'import json,sys; print("\n".join("%s:%s" % (proof["line"], proof["grade"]) for proof in json.load(open(sys.argv[1]))["proofs"]))' "$reports/verify.json"; }
json_not_checked_lines() { python3 -c 'import json,sys; print(" ".join("%s:%s:%s" % (entry["line"], entry["grade"], entry["reason"]) for entry in json.load(open(sys.argv[1]))["not_checked"]))' "$reports/verify.json"; }
json_not_checked_grades() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (entry["line"], entry["grade"]) for entry in json.load(open(sys.argv[1]))["not_checked"]))' "$reports/verify.json"; }
not_checked_bullets() { awk '/^## / { in_list = ($0 == "## Not checked") } in_list && /^- /' "$reports/verify.md"; }

echo "one proof of each grade, all holding"
new_item every-grade "$(capture_gate every-grade)"
write_capture every-grade "mkdir -p '$reports/evidence' && echo png > '$reports/evidence/login-error.png'"
commit_test_command true
write_proofs "[{\"line\": 1, \"text\": \"greet prints hello\", \"grade\": \"test\", \"test\": \"$test_name\"},
  {\"line\": 2, \"text\": \"the login error shows\", \"grade\": \"live\", \"evidence\": \"evidence/login-error.png\"},
  {\"line\": 3, \"text\": \"the client renders\", \"grade\": \"build-only\", \"reason\": \"$build_only_reason\"},
  {\"line\": 4, \"text\": \"the staging deploy works\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
check "ProofsFileBeforeTheRun_NoReportYet: the reports come from verify, never from the suite" \
  '[ ! -e "$reports/verify.json" ] && [ ! -e "$reports/verify.md" ]'
verify >/dev/null 2>&1
every_grade_code=$?
check "EveryGradeHolding_MarkdownSecondLineCountsTheLiveAndTestLines: two of the four lines are proven live or by test" \
  '[ "$(count_line)" = "2 of 4 acceptance lines proven live or by test" ]'
check "EveryGradeHolding_JsonProvenIsTwo: the JSON counts the live and the test line alone" \
  '[ "$(report_value proven)" = 2 ]'
check "EveryGradeHolding_JsonAcceptanceLinesIsFour: every entry of the proofs file is one acceptance line" \
  '[ "$(report_value acceptance_lines)" = 4 ]'
check "EveryGradeHolding_JsonGivesEachLineItsOneGrade: each line keeps the grade the verifier gave it" \
  '[ "$(json_proof_grades | tr "\n" " ")" = "1:test 2:live 3:build-only 4:blocked " ]'
check "EveryGradeHolding_JsonLiveProofCarriesItsEvidence: a reviewer opens the captured file from the proof" \
  '[ "$(report_value proofs.1.evidence)" = evidence/login-error.png ]'
check "EveryGradeHolding_JsonTestProofNamesItsTest: a reviewer finds the test that proves the line" \
  '[ "$(report_value proofs.0.test)" = "$test_name" ]'
check "EveryGradeHolding_MarkdownTableHasOneRowPerLineWithItsGrade: the Markdown shows each line once with one grade" \
  '[ "$(proof_rows | tr "\n" " ")" = "1:test 2:live 3:build-only 4:blocked " ]'
check "EveryGradeHolding_MarkdownLiveRowLinksTheFile: the link opens the evidence relative to verify.md" \
  'proof_row 2 | grep -qF "](<evidence/login-error.png>)"'
check "EveryGradeHolding_MarkdownTestRowNamesTheTest: a reader of the Markdown finds the proving test" \
  'proof_row 1 | grep -qF "\`$test_name\`"'
check "EveryGradeHolding_JsonAndMarkdownNameTheSameLinesAndGrades: both reports come from one grading" \
  '[ -n "$(proof_rows)" ] && [ "$(proof_rows)" = "$(json_proof_grades)" ]'
check "BuildOnlyAndBlockedLines_JsonNotCheckedHoldsBothWithTheirReasons: a reviewer sees what was left out and why" \
  '[ "$(json_not_checked_lines)" = "3:build-only:$build_only_reason 4:blocked:$blocked_reason" ]'
check "BuildOnlyAndBlockedLines_MarkdownNotCheckedListsBothWithTheirReasons: the Markdown list says the same" \
  '[ "$(not_checked_bullets | tr "\n" "|")" = "- Line 3, build-only: $build_only_reason.|- Line 4, blocked: $blocked_reason.|" ]'
check "BuildOnlyAndBlockedLinesWithEveryCheckPassing_StatusIsPass: a line left unchecked never fails verify" \
  '[ "$(report_status)" = pass ]'
check "BuildOnlyAndBlockedLinesWithEveryCheckPassing_VerifyExitsZero: the caller reads a pass from the exit code too" \
  '[ "$every_grade_code" -eq 0 ]'

echo "proofs that do not hold"
new_item faulty "$(capture_gate faulty)"
write_capture faulty "mkdir -p '$reports/evidence/folder' && echo txt > '$reports/outside.txt' && echo txt > '$work/outside.txt' && ln -s '$work/outside.txt' '$reports/evidence/link.png'"
write_proofs '[{"line": 1, "text": "missing", "grade": "live", "evidence": "evidence/missing.png"},
  {"line": 2, "text": "climbs", "grade": "live", "evidence": "evidence/../outside.txt"},
  {"line": 3, "text": "linked out", "grade": "live", "evidence": "evidence/link.png"},
  {"line": 4, "text": "a folder", "grade": "live", "evidence": "evidence/folder"},
  {"line": 5, "text": "no reason", "grade": "build-only"},
  {"line": 6, "text": "unknown grade", "grade": "proven", "reason": "x"},
  {"line": 7, "text": "first of two", "grade": "blocked", "reason": "x"},
  {"line": 7, "text": "second of two", "grade": "blocked", "reason": "y"}]'
verify >/dev/null 2>&1
check "LiveProofWithNoCapturedFile_IsAnError: a line cannot claim a live check with no captured file" \
  '[ "$(report_value proofs.0.grade)" = error ]'
check "LiveProofWithNoCapturedFile_ClaimedIsLive: the reviewer sees which grade the verifier wrote" \
  '[ "$(report_value proofs.0.claimed)" = live ]'
check "LiveProofWithNoCapturedFile_IsInNotChecked: a line that does not hold is listed as not checked" \
  'not_checked_bullets | grep -q "^- Line 1, error: "'
check "LiveProofClimbingOutOfEvidence_IsAnError: a path through .. is no captured file" \
  '[ "$(report_value proofs.1.grade)" = error ]'
check "LiveProofThroughALinkOutOfEvidence_IsAnError: a link that leaves evidence/ is no captured file" \
  '[ "$(report_value proofs.2.grade)" = error ]'
check "LiveProofNamingAFolder_IsAnError: only a regular file is a captured file" \
  '[ "$(report_value proofs.3.grade)" = error ]'
check "BuildOnlyProofWithNoReason_IsAnError: build-only needs its reason" \
  '[ "$(report_value proofs.4.grade)" = error ]'
check "BuildOnlyProofWithNoReason_ReasonSaysItGivesNone: the verifier learns what to add" \
  'report_value proofs.4.reason | grep -q "no reason"'
check "ProofWithAnUnknownGrade_IsAnError: only live, test, build-only and blocked are grades" \
  '[ "$(report_value proofs.5.grade)" = error ]'
check "ProofWithAnUnknownGrade_ReasonNamesTheGrade: the verifier learns which grade was wrong" \
  'report_value proofs.5.reason | grep -q "proven"'
check "FirstOfTwoProofsOfOneLine_IsAnError: each line carries exactly one grade" \
  '[ "$(report_value proofs.6.grade)" = error ]'
check "SecondOfTwoProofsOfOneLine_IsAnError: neither proof of a line graded twice is the one to trust" \
  '[ "$(report_value proofs.7.grade)" = error ]'
check "TwoProofsOfOneLine_ReasonSaysTheLineIsGradedTwice: the verifier learns which line to fix" \
  'report_value proofs.6.reason | grep -q "more than once"'
check "LiveProofWithNoCapturedFile_MarkdownRowGradesItError: the Markdown never shows the claimed live grade" \
  '[ "$(proof_rows | head -n 1)" = "1:error" ]'
check "LiveProofWithNoCapturedFile_JsonNotCheckedHoldsTheLineAsAnError: a reader of the JSON sees the line was not proven" \
  'json_not_checked_lines | grep -q "^1:error:"'
check "ProofsThatDoNotHold_MarkdownCountsNoLine: an error is never counted as proven" \
  '[ "$(count_line)" = "0 of 8 acceptance lines proven live or by test" ]'
check "ProofsThatDoNotHoldWithEveryCheckPassing_StatusIsPass: a proof is the verifier's fault, never a failed check of the code" \
  '[ "$(report_status)" = pass ]'
check "ProofsThatDoNotHold_CaptureGateRan: the link and the folder the live proofs name were there to be refused" \
  '[ -L "$reports/evidence/link.png" ] && [ -d "$reports/evidence/folder" ]'

echo "a proofs file written for another commit"
new_item stale "  ok: 'true'"
write_proofs "[{\"line\": 1, \"text\": \"a\", \"grade\": \"build-only\", \"reason\": \"$build_only_reason\"},
  {\"line\": 2, \"text\": \"b\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
printf 'y\n' > "$worktree/later.txt" && git -C "$worktree" add -A && git -C "$worktree" commit -qm later
verify >/dev/null 2>&1
check "ProofsFileForAnotherCommit_GradesEveryLineAnError: proofs of an older commit prove nothing about this one" \
  '[ "$(json_proof_grades | tr "\n" " ")" = "1:error 2:error " ]'
check "ProofsFileForAnotherCommit_CountsNoLine: the count is 0 of the file's lines" \
  '[ "$(count_line)" = "0 of 2 acceptance lines proven live or by test" ]'

check "ProofsFileForAnotherCommit_JsonNotCheckedHoldsEveryLine: each line of a stale file is listed as not checked" \
  '[ "$(json_not_checked_grades)" = "1:error 2:error" ]'

echo "a proof whose text cannot be written as UTF-8"
new_item surrogate "  ok: 'true'"
write_proofs '[{"line": 1, "text": "half a pair \ud800", "grade": "blocked", "reason": "the staging server is down"}]'
verify >/dev/null 2>&1
check "ProofWithALoneSurrogate_StatusIsTheChecksStatus: the proofs file never stops the report being built" \
  '[ "$(report_status)" = pass ]'
check "ProofWithALoneSurrogate_MarkdownListsTheLine: the line still reaches the Not checked list" \
  'not_checked_bullets | grep -q "^- Line 1, blocked: "'

echo "a test proof in a run whose tests failed"
new_item failed-tests ""
commit_test_command false
write_proofs "[{\"line\": 1, \"text\": \"greet prints hello\", \"grade\": \"test\", \"test\": \"$test_name\"}]"
verify >/dev/null 2>&1
check "TestProofWithTheTestsCheckFailed_IsAnError: test means a test passed in this run" \
  '[ "$(report_value proofs.0.grade)" = error ]'
check "TestProofWithTheTestsCheckFailed_ClaimedIsTest: the reviewer sees which grade the verifier wrote" \
  '[ "$(report_value proofs.0.claimed)" = test ]'

echo "a proofs file that is not JSON"
new_item not-json "  ok: 'true'"
printf 'not json {\n' > "$reports/proofs.json"
verify >/dev/null 2>&1
check "ProofsFileNotJson_StatusIsTheChecksStatus: the proofs file never fails verify" \
  '[ "$(report_status)" = pass ]'
check "ProofsFileNotJson_MarkdownCountsNoLines: no line is graded from a file verify cannot read" \
  '[ "$(count_line)" = "0 of 0 acceptance lines proven live or by test" ]'
check "ProofsFileNotJson_NotCheckedNamesTheFile: the reviewer learns the proofs were unreadable" \
  'not_checked_bullets | grep -q "^- proofs.json, error: "'

echo "line numbers outside the file and a test proof with no name"
new_item out-of-range ""
commit_test_command true
write_proofs '[{"line": 0, "text": "before the first", "grade": "blocked", "reason": "x"},
  {"line": 4, "text": "past the last", "grade": "blocked", "reason": "x"},
  {"line": 2, "text": "unnamed test", "grade": "test", "test": ""}]'
verify >/dev/null 2>&1
check "ProofOfLineZero_IsAnError: lines are numbered from one" \
  '[ "$(report_value proofs.0.grade)" = error ]'
check "ProofOfALinePastTheFile_IsAnError: a line number above the number of entries names no acceptance line" \
  '[ "$(report_value proofs.1.grade)" = error ]'
check "TestProofWithNoTestName_IsAnError: a test proof must name the test a reviewer can find" \
  '[ "$(report_value proofs.2.grade)" = error ]'
check "TestProofWithNoTestNameWithTheTestsCheckPassing_IsNotCounted: a passing tests check alone proves no line" \
  '[ "$(count_line)" = "0 of 3 acceptance lines proven live or by test" ]'

echo "a proofs file that is a list, not an object"
new_item bare-list "  ok: 'true'"
printf '[{"line": 1, "text": "a", "grade": "blocked", "reason": "x"}]\n' > "$reports/proofs.json"
verify >/dev/null 2>&1
check "ProofsFileThatIsAList_MarkdownCountsNoLines: only an object with a proofs list is a proofs file" \
  '[ "$(count_line)" = "0 of 0 acceptance lines proven live or by test" ]'
check "ProofsFileThatIsAList_NotCheckedNamesTheFile: the reviewer learns the proofs file had the wrong shape" \
  'not_checked_bullets | grep -q "^- proofs.json, error: "'
check "ProofsFileThatIsAList_StatusIsTheChecksStatus: a proofs file of the wrong shape never fails verify" \
  '[ "$(report_status)" = pass ]'

if [ "$fails" -eq 0 ]; then echo "verify-proofs: ok"; else echo "verify-proofs: $fails failed"; exit 1; fi
