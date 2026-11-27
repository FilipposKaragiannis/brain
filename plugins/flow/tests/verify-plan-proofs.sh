#!/bin/sh
# verify-plan-proofs.sh: verify grades a line the plan names in its Acceptance section, with
# `Proof: <path> by <capture>`, live from the plan's file when that file holds: the plan's path is
# the evidence, its capture is carried, and the line counts as proven, whatever grade or file the
# verifier wrote for it and whichever commit its proofs file was written for. A named file that is
# missing, empty, a link out of evidence/ or a path through `..` fails verify: the check
# `plan proofs` fails naming the file, and the line is graded error; so does a named line that no
# entry of proofs.json grades, or that two entries grade, naming the plan and the line. A malformed `Proof:` line in the section (no
# path, no capture, before any numbered line, a second for one line, a path that is absolute, goes
# through `..` or is outside evidence/) fails verify naming its line in plan.md. No plan, no
# section, a section with no `Proof:` and a `Proof:` outside the section give the report of a run
# with no plan, and an unnamed live proof whose file is empty still passes. Each run's gate writes
# the evidence, as a capture does, and the suite writes plan.md and proofs.json alone, never a
# report. On the local adapter in throwaway repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

other_line=1
named_line=2
line_after_the_named_one=3
lines_proven_by_the_plan=1
named_entry=1
plan_file_line=0
first_not_checked_entry=0
no_acceptance_lines=0
named_text="the score shows after a goal"
named_evidence=evidence/score-after-goal.png
named_capture="the replay test ScoreBoard_AfterAGoal_ShowsTheScore"
verifier_evidence=evidence/never-captured.png
empty_evidence=evidence/client-builds.png
first_section_plan_line=5
proof_plan_line=6
second_proof_plan_line=7
unnamed_entry=0
plan_header="# the score shows
Goal: the player sees the score.
"
blocked_reason="the staging server is down"
capture_gate() { printf "  capture: 'sh %s/capture-%s.sh'\n" "$work" "$1"; }
write_capture() { printf '%s\n' "$2" > "$work/capture-$1.sh"; }
capture_named_file() { write_capture "$1" "mkdir -p '$reports/evidence' && echo png > '$reports/$named_evidence'"; }
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
write_plan_text() { printf '%s\n' "$1" > "$reports/plan.md"; }
write_acceptance() {
  write_plan_text "$plan_header
## Acceptance
$1

## Phase 1: The score
- [ ] Draw the score."
}
write_plan() { write_acceptance "$named_line. $named_text
   Proof: $1 by $named_capture"; }
report_value() { json_value "$1" < "$reports/verify.json"; }
json_proof_grades() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (proof["line"], proof["grade"]) for proof in json.load(open(sys.argv[1]))["proofs"]))' "$reports/verify.json"; }
check_status() { python3 -c 'import json,sys; print("".join(check["status"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]))' "$reports/verify.json" "$1"; }
check_summary() { python3 -c 'import json,sys; print("".join(check["summary"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]))' "$reports/verify.json" "$1"; }
append_evidence() { printf 'evidence:\n%s\n' "$1" >> "$root/app/.flow/config.yaml"; }
write_blocked_proofs() {
  write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
}
named_file_fails() {
  named_file_fails_path="$2"
  check "${1}_ReportSaysFail: a named file that does not hold fails verify" \
    '[ "$(report_status)" = fail ]'
  check "${1}_PlanProofsCheckFails: the report names the plan proofs check as the one that failed" \
    '[ "$(check_status "plan proofs")" = fail ]'
  check "${1}_CheckSummaryNamesTheFile: the summary tells the verifier which file no capture wrote" \
    'check_summary "plan proofs" | grep -qF -- "$named_file_fails_path"'
  check "${1}_MarkdownNamesTheFile: the PR body names the file that does not hold" \
    'grep -qF -- "$named_file_fails_path" "$reports/verify.md"'
}
malformed_proof_fails() {
  malformed_proof_fails_line="plan.md line $2"
  check "${1}_ReportSaysFail: a malformed proof fails verify" \
    '[ "$(report_status)" = fail ]'
  check "${1}_PlanProofsCheckFails: the report names the plan proofs check as the one that failed" \
    '[ "$(check_status "plan proofs")" = fail ]'
  check "${1}_CheckSummaryNamesThePlanLine: the summary tells the planner which line of plan.md to fix" \
    'check_summary "plan proofs" | grep -qF -- "$malformed_proof_fails_line:"'
  check "${1}_MarkdownNamesThePlanLine: the PR body names the line of plan.md to fix" \
    'grep -qF -- "$malformed_proof_fails_line:" "$reports/verify.md"'
}
malformed_proof_case() { new_item "$1" "$(capture_gate "$1")"; capture_named_file "$1"; write_acceptance "$2"; write_blocked_proofs; verify >/dev/null 2>&1; }
json_without_timings() { python3 -c 'import json,sys
report=json.load(open(sys.argv[1])); report.pop("seconds",None)
for check in report["checks"]: check.pop("seconds",None)
print(json.dumps(report,sort_keys=True))' "$reports/verify.json"; }
markdown_without_timings() { python3 -c 'import re,sys
print(re.sub(r"^The run took .*$|(?<=\| )\d+(?:s|m \d+s|h \d+m)(?= \|)","",open(sys.argv[1]).read(),flags=re.M))' "$reports/verify.md"; }
verifies_as_with_no_plan() {
  check "${1}_JsonEqualsARunWithNoPlan: a plan that names no proof leaves verify.json as it is today" \
    'json_without_timings | diff -- "$work/no-plan.json" -'
  check "${1}_MarkdownEqualsARunWithNoPlan: a plan that names no proof leaves verify.md as it is today" \
    'markdown_without_timings | diff -- "$work/no-plan.md" -'
  check "${1}_ReportHasNoPlanProofsCheck: a plan that names no proof adds no check" \
    '[ -z "$(check_status "plan proofs")" ]'
}
json_not_checked_grades() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (entry["line"], entry["grade"]) for entry in json.load(open(sys.argv[1]))["not_checked"]))' "$reports/verify.json"; }

echo "a named file that holds"
new_item holds "$(capture_gate holds)"
capture_named_file holds
write_plan "$named_evidence"
write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"live\", \"evidence\": \"$verifier_evidence\"}]"
verify >/dev/null 2>&1
check "NamedFileThatHolds_JsonGradesTheLineLive: the line the plan names is proven by its captured file" \
  '[ "$(report_value proofs.$named_entry.grade)" = live ]'
check "NamedFileThatHolds_JsonEvidenceIsThePlansFile: the file the plan named is the evidence, not the one the verifier picked" \
  '[ "$(report_value proofs.$named_entry.evidence)" = "$named_evidence" ]'
check "NamedFileThatHolds_JsonCarriesThePlansCapture: a reviewer learns what captured the file" \
  '[ "$(report_value proofs.$named_entry.capture)" = "$named_capture" ]'
check "NamedFileThatHolds_JsonKeepsTheVerifiersText: the acceptance text still comes from the proofs file" \
  '[ "$(report_value proofs.$named_entry.text)" = "$named_text" ]'
check "NamedFileThatHolds_JsonProvenCountsTheLine: a named line that holds counts as proven" \
  '[ "$(report_value proven)" = "$lines_proven_by_the_plan" ]'
check "NamedFileThatHolds_MarkdownRowLinksThePlansFile: the Proofs table opens the file the plan named" \
  'grep -qF "](<$named_evidence>)" "$reports/verify.md"'
check "NamedFileThatHolds_PlanProofsCheckPasses: a named file that holds is a check that passed" \
  '[ "$(check_status "plan proofs")" = pass ]'

echo "the verifier wrote another grade for the named line"
new_item overridden "$(capture_gate overridden)"
capture_named_file overridden
write_plan "$named_evidence"
write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
verify >/dev/null 2>&1
check "NamedLineTheVerifierGradedBlocked_JsonGradesItLive: the plan's proof wins over the verifier's grade" \
  '[ "$(json_proof_grades)" = "$other_line:blocked $named_line:live" ]'
check "NamedLineTheVerifierGradedBlocked_JsonNotCheckedLeavesItOut: a named line that holds is never listed as not checked" \
  '[ "$(json_not_checked_grades)" = "$other_line:blocked" ]'

echo "a proofs file written for another commit"
new_item stale "$(capture_gate stale)"
capture_named_file stale
write_plan "$named_evidence"
write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"live\", \"evidence\": \"$verifier_evidence\"}]"
printf 'y\n' > "$worktree/later.txt" && git -C "$worktree" add -A && git -C "$worktree" commit -qm later
verify >/dev/null 2>&1
check "StaleProofsFileWithANamedLine_JsonGradesTheNamedLineLive: the named file is captured in this run, so the head of the proofs file never touches it" \
  '[ "$(report_value proofs.$named_entry.grade)" = live ]'
check "StaleProofsFileWithANamedLine_JsonGradesTheOtherLinesErrors: a line the plan does not name still needs a proofs file of this commit" \
  '[ "$(json_not_checked_grades)" = "$other_line:error" ]'

echo "a named file no capture wrote"
new_item missing "  ok: 'true'"
write_plan "$named_evidence"
write_blocked_proofs
verify >/dev/null 2>&1
named_file_fails NamedFileMissing "$named_evidence"
check "NamedFileMissing_JsonGradesTheLineError: the plan's claim wins over the verifier's grade, and it does not hold" \
  '[ "$(report_value proofs.$named_entry.grade)" = error ]'
check "NamedFileMissing_JsonClaimedIsLive: the report says the line was claimed live, as the plan names it" \
  '[ "$(report_value proofs.$named_entry.claimed)" = live ]'
check "NamedFileMissing_JsonReasonNamesThePlansFile: the reason says which file the plan named" \
  'report_value proofs.$named_entry.reason | grep -qF -- "$named_evidence"'

echo "a named file that is empty"
new_item empty "$(capture_gate empty)"
write_capture empty "mkdir -p '$reports/evidence' && : > '$reports/$named_evidence'"
write_plan "$named_evidence"
write_blocked_proofs
verify >/dev/null 2>&1
named_file_fails NamedFileEmpty "$named_evidence"

echo "a named file that links out of the evidence folder"
outside_file="$work/outside.png"
printf 'png\n' > "$outside_file"
new_item linked "$(capture_gate linked)"
write_capture linked "mkdir -p '$reports/evidence' && ln -s '$outside_file' '$reports/$named_evidence'"
write_plan "$named_evidence"
write_blocked_proofs
verify >/dev/null 2>&1
named_file_fails NamedFileLinkingOutOfEvidence "$named_evidence"

echo "a named path that leaves the evidence folder through .."
parent_evidence=evidence/../score-after-goal.png
new_item parent "$(capture_gate parent)"
write_capture parent "mkdir -p '$reports/evidence' && echo png > '$reports/score-after-goal.png'"
write_plan "$parent_evidence"
write_blocked_proofs
verify >/dev/null 2>&1
named_file_fails NamedPathThroughParent "$parent_evidence"

echo "the capture of the named file is skipped by its paths"
new_item skipped "  ok: 'true'"
write_capture skipped "mkdir -p '$reports/evidence' && echo png > '$reports/$named_evidence'"
append_evidence "  score:
    command: 'sh $work/capture-skipped.sh'
    paths: [nothing-changed-here/**]"
write_plan "$named_evidence"
write_blocked_proofs
verify >/dev/null 2>&1
named_file_fails NamedFileWhoseCaptureIsSkipped "$named_evidence"

echo "a named proof with no proofs file"
new_item unmatched "$(capture_gate unmatched)"
capture_named_file unmatched
write_plan "$named_evidence"
verify >/dev/null 2>&1
check "NamedLineWithNoProofsFile_ReportSaysFail: a named line with no line in proofs.json fails verify" \
  '[ "$(report_status)" = fail ]'
check "NamedLineWithNoProofsFile_PlanProofsCheckFails: the report names the plan proofs check as the one that failed" \
  '[ "$(check_status "plan proofs")" = fail ]'
check "NamedLineWithNoProofsFile_CheckSummaryNamesThePlanAndTheLine: the verifier learns which plan line has no proofs entry" \
  'check_summary "plan proofs" | grep -F -- plan.md | grep -qF -- "line $named_line"'
check "NamedLineWithNoProofsFile_JsonNotCheckedHasThePlanEntry: the line the plan names is listed as not checked, on line 0" \
  '[ "$(json_not_checked_grades)" = "$plan_file_line:error" ]'
check "NamedLineWithNoProofsFile_JsonNotCheckedNamesThePlan: the not checked entry names plan.md" \
  '[ "$(report_value not_checked.$first_not_checked_entry.text)" = plan.md ]'
check "NamedLineWithNoProofsFile_JsonAcceptanceLinesCountsTheProofsFile: the plan adds no acceptance line of its own" \
  '[ "$(report_value acceptance_lines)" = "$no_acceptance_lines" ]'

named_line_fails() {
  check "${1}_ReportSaysFail: a named line with no single proofs entry fails verify" \
    '[ "$(report_status)" = fail ]'
  check "${1}_PlanProofsCheckFails: the report names the plan proofs check as the one that failed" \
    '[ "$(check_status "plan proofs")" = fail ]'
  check "${1}_CheckSummaryNamesThePlanAndTheLine: the verifier learns which plan line has no single proofs entry" \
    'check_summary "plan proofs" | grep -F -- plan.md | grep -qF -- "line $named_line"'
}

echo "a named line no proofs entry grades"
new_item absentline "$(capture_gate absentline)"
capture_named_file absentline
write_plan "$named_evidence"
write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $line_after_the_named_one, \"text\": \"$named_text\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
verify >/dev/null 2>&1
named_line_fails NamedLineNoProofsEntryGrades

echo "a named line two proofs entries grade"
new_item repeatedline "$(capture_gate repeatedline)"
capture_named_file repeatedline
write_plan "$named_evidence"
write_proofs "[{\"line\": $named_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
verify >/dev/null 2>&1
named_line_fails NamedLineTwoProofsEntriesGrade

echo "a proof with no path"
malformed_proof_case nopath "$named_line. $named_text
   Proof: by $named_capture"
malformed_proof_fails ProofWithNoPath "$proof_plan_line"

echo "a proof with no capture"
malformed_proof_case nocapture "$named_line. $named_text
   Proof: $named_evidence"
malformed_proof_fails ProofWithNoCapture "$proof_plan_line"

echo "a proof before any numbered line"
malformed_proof_case leading "   Proof: $named_evidence by $named_capture
$named_line. $named_text"
malformed_proof_fails ProofBeforeAnyNumberedLine "$first_section_plan_line"

echo "a second proof for the same line"
malformed_proof_case second "$named_line. $named_text
   Proof: $named_evidence by $named_capture
   Proof: $named_evidence by $named_capture"
malformed_proof_fails SecondProofForTheSameLine "$second_proof_plan_line"

echo "a proof with an absolute path"
new_item absolute "$(capture_gate absolute)"
capture_named_file absolute
write_acceptance "$named_line. $named_text
   Proof: $reports/$named_evidence by $named_capture"
write_blocked_proofs
verify >/dev/null 2>&1
malformed_proof_fails ProofWithAnAbsolutePath "$proof_plan_line"

echo "a proof whose path goes through .."
malformed_proof_case throughparent "$named_line. $named_text
   Proof: evidence/../$named_evidence by $named_capture"
malformed_proof_fails ProofPathThroughParent "$proof_plan_line"

echo "a proof whose path is outside evidence/"
malformed_proof_case outside "$named_line. $named_text
   Proof: shots/score-after-goal.png by $named_capture"
malformed_proof_fails ProofPathOutsideEvidence "$proof_plan_line"

echo "no plan, and an unnamed live proof whose file is empty"
new_item unnamed "$(capture_gate unnamed)"
write_capture unnamed "mkdir -p '$reports/evidence' && : > '$reports/$empty_evidence'"
write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"live\", \"evidence\": \"$empty_evidence\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"}]"
verify >/dev/null 2>&1
check "NoPlan_ReportHasNoPlanProofsCheck: with no plan.md verify adds no check" \
  '[ -z "$(check_status "plan proofs")" ]'
check "UnnamedLiveProofWithAnEmptyFile_ReportSaysPass: an empty file fails only a proof the plan names" \
  '[ "$(report_status)" = pass ]'
check "UnnamedLiveProofWithAnEmptyFile_JsonGradesItLive: a captured file the plan does not name holds when empty, as today" \
  '[ "$(report_value proofs.$unnamed_entry.grade)" = live ]'
json_without_timings > "$work/no-plan.json"
markdown_without_timings > "$work/no-plan.md"

echo "a plan with no Acceptance section"
write_plan_text "$plan_header
## Phase 1: The score
- [ ] Draw the score."
verify >/dev/null 2>&1
verifies_as_with_no_plan PlanWithNoAcceptanceSection

echo "an Acceptance section with numbered lines and no proof"
write_acceptance "$other_line. the client builds
$named_line. $named_text"
verify >/dev/null 2>&1
verifies_as_with_no_plan AcceptanceSectionWithNoProof

echo "a plan whose only proof sits outside the Acceptance section"
write_acceptance "$other_line. the client builds
$named_line. $named_text

## Notes
   Proof: $verifier_evidence by $named_capture"
verify >/dev/null 2>&1
verifies_as_with_no_plan ProofOutsideTheAcceptanceSection

if [ "$fails" -eq 0 ]; then echo "verify-plan-proofs: ok"; else echo "verify-plan-proofs: $fails failed"; exit 1; fi
