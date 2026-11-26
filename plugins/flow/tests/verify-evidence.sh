#!/bin/sh
# verify-evidence.sh: the evidence list in .flow/config.yaml runs after the gates as the checks
# `evidence <name>`, each writing its files into FLOW_EVIDENCE_FOLDER, <reports>/evidence; a capture
# that fails fails verify, one whose paths match no changed file is skipped, a config with no
# evidence key adds no check and no folder, and no gate sees the folder. A started run and a plain
# run both remove the earlier run's evidence, and a link left at that name goes without its target.
# On the local adapter in throwaway repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"
unset FLOW_EVIDENCE_FOLDER

printf 'printf "png\\n" > "$FLOW_EVIDENCE_FOLDER/$1"\n' > "$work/capture.sh"
printf 'echo "capture broke" >&2; exit 1\n' > "$work/broken-capture.sh"
printf 'printf "%%s" "${FLOW_EVIDENCE_FOLDER-unset}" > "$1"\n' > "$work/record-folder.sh"
check_names() { python3 -c 'import json,sys; print("\n".join(check["name"] for check in json.load(open(sys.argv[1]))["checks"]))' "$reports/verify.json"; }
check_status() { python3 -c 'import json,sys; print("".join(check["status"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]))' "$reports/verify.json" "$1"; }
last_check_line_starting_with() { check_names | grep -n "^$1" | tail -n 1 | cut -d: -f1; }
append_evidence() { printf 'evidence:\n%s\n' "$1" >> "$root/app/.flow/config.yaml"; }
leave_earlier_evidence() { mkdir -p "$reports/evidence" && printf 'png\n' > "$reports/evidence/old.png"; }
# A --start call returns at once, and a held gate starts within seconds; past these bounds the
# check fails instead of hanging the suite.
start_return_seconds=30
gate_start_seconds=20

echo "a capture writes its file into the evidence folder"
new_item shot "  ok: 'true'"
append_evidence "  shot: 'sh $work/capture.sh shot.png'"
verify >/dev/null 2>&1
check "CaptureWritingIntoTheFolder_LeavesItsFileUnderReportsEvidence: the PR step reads the file from the reports folder" \
  '[ -f "$reports/evidence/shot.png" ]'
check "CaptureThatExitsZero_IsAPassedEvidenceCheck: the report names the capture as a check that passed" \
  '[ "$(check_status "evidence shot")" = pass ]'
check "CaptureCheck_ComesAfterTheLastGate: evidence is captured from the change the gates passed" \
  '[ "$(last_check_line_starting_with "evidence shot")" -gt "$(last_check_line_starting_with "gate ")" ]'

echo "every configured capture runs, in either form"
new_item both "  ok: 'true'"
append_evidence "  plain: 'sh $work/capture.sh plain.png'
  mapped:
    command: 'sh $work/capture.sh mapped.png'
    paths: [change.txt]"
verify >/dev/null 2>&1
check "TwoCaptures_FirstLeavesItsFile: every configured capture runs, not only one" \
  '[ -f "$reports/evidence/plain.png" ]'
check "CaptureMapWithPathsMatchingAChangedFile_LeavesItsFile: a map entry runs when its paths match, as a gate does" \
  '[ -f "$reports/evidence/mapped.png" ]'

echo "a capture that fails fails verify"
new_item broken "  ok: 'true'"
append_evidence "  broken: 'sh $work/broken-capture.sh'"
verify >/dev/null 2>&1; broken_code=$?
check "CaptureThatExitsNonZero_IsAFailedEvidenceCheck: the report names the capture that failed" \
  '[ "$(check_status "evidence broken")" = fail ]'
check "CaptureThatExitsNonZero_ReportSaysFail: a missing proof file is a failed run, not a pass" \
  '[ "$(report_status)" = fail ]'
check "CaptureThatExitsNonZero_VerifyExitsOne: the caller reads a fail from the exit code" \
  '[ "$broken_code" -eq 1 ]'

echo "a capture whose paths match no changed file"
new_item scoped "  ok: 'true'"
append_evidence "  scoped:
    command: 'sh $work/capture.sh scoped.png'
    paths: [src/**]"
verify >/dev/null 2>&1
check "ScopedRun_ReportListsChecks: an empty check list would pass the row below on nothing" \
  '[ -n "$(check_names)" ]'
check "ScopedRun_ChangeListIsComplete: an incomplete list runs every check with paths, so the rows below would prove nothing" \
  '! check_names | grep -qx "changed files"'
check "CaptureWithPathsMatchingNoChangedFile_IsASkippedEvidenceCheck: the report says why no evidence came" \
  '[ "$(check_status "evidence scoped")" = skipped ]'
check "CaptureWithPathsMatchingNoChangedFile_WritesNothing: a skipped capture must not run" \
  '[ ! -f "$reports/evidence/scoped.png" ]'

echo "a config with no evidence key"
new_item plain "  ok: 'true'"
verify >/dev/null 2>&1
check "ConfigWithNoEvidenceKey_ReportListsChecks: an empty check list would pass the row below on nothing" \
  '[ -n "$(check_names)" ]'
check "ConfigWithNoEvidenceKey_HasNoEvidenceCheck: a project that captures nothing keeps its check list" \
  '! check_names | grep -q "^evidence"'
check "ConfigWithNoEvidenceKey_MakesNoEvidenceFolder: a project that captures nothing gets no folder" \
  '[ ! -e "$reports/evidence" ]'

echo "no gate sees the evidence folder"
new_item hidden "  record: 'sh $work/record-folder.sh $work/gate-saw'"
append_evidence "  record: 'sh $work/record-folder.sh $work/capture-saw'"
verify >/dev/null 2>&1
check "CaptureInTheSameRun_SeesTheEvidenceFolder: the folder must be set in this run, or the next check proves nothing" \
  '[ "$(cat "$work/capture-saw")" = "$reports/evidence" ]'
check "GateBeforeTheCaptures_DoesNotSeeTheEvidenceFolder: a gate writing into the folder would mix its files with the evidence" \
  '[ "$(cat "$work/gate-saw")" = unset ]'

echo "a started run removes the earlier run's evidence"
new_item cleared "$(held_gate cleared)"
leave_earlier_evidence
(verify --start >/dev/null 2>&1; echo "$?" > "$work/cleared-start.code") &
check "StartWithAnEarlierEvidenceFile_ReturnsAtOnce: the row below must read the folder while the run goes" \
  'until_true "$start_return_seconds" "[ -s $work/cleared-start.code ]"'
check "StartedRun_GateIsHeld: the gate must still run, or the row below cannot tell a cleared start from an ended run" \
  'until_true "$gate_start_seconds" "[ -s $work/cleared.count ]"'
check "StartAfterAnEarlierRun_RemovesTheEarlierEvidence: no file of an earlier run may read as this run's proof" \
  '[ ! -e "$reports/evidence/old.png" ]'
touch "$work/release-cleared"
wait_until_ended

echo "a plain run removes the earlier run's evidence and keeps its own"
new_item fresh "  ok: 'true'"
append_evidence "  new: 'sh $work/capture.sh new.png'"
leave_earlier_evidence
verify >/dev/null 2>&1
check "PlainRunAfterAnEarlierRun_RemovesTheEarlierEvidence: a direct run starts as clean as a started one" \
  '[ ! -e "$reports/evidence/old.png" ]'
check "PlainRunAfterAnEarlierRun_KeepsItsOwnCapture: the clearing comes before the captures, never after" \
  '[ -f "$reports/evidence/new.png" ]'

echo "a link left at the evidence folder"
new_item linked "  ok: 'true'"
mkdir -p "$work/outside" && printf 'png\n' > "$work/outside/kept.png"
ln -s "$work/outside" "$reports/evidence"
verify >/dev/null 2>&1
check "LinkAtTheEvidenceFolder_IsRemoved: a run never writes its evidence through a link someone left" \
  '[ ! -L "$reports/evidence" ]'
check "LinkAtTheEvidenceFolder_LeavesItsTargetFilesAlone: clearing the evidence never reaches outside the reports" \
  '[ -f "$work/outside/kept.png" ]'

echo "earlier evidence that cannot be removed"
if [ "$(id -u)" -eq 0 ]; then
  echo "skipped: root removes a file in a read-only folder, so the earlier evidence cannot be made to stay"
else
  new_item stuck "  ok: 'true'"
  mkdir -p "$reports/evidence/locked" && printf 'png\n' > "$reports/evidence/locked/old.png" && chmod a-w "$reports/evidence/locked"
  verify >/dev/null 2>&1; stuck_code=$?
  check "PlainRunWithUndeletableEarlierEvidence_ExitsOne: a run must not pass while an earlier run's file could read as its proof" \
    '[ "$stuck_code" -eq 1 ]'
  check "PlainRunWithUndeletableEarlierEvidence_WritesNoReport: the run stops before any check, so no report can pass" \
    '[ ! -f "$reports/verify.json" ]'
  verify --start >/dev/null 2>&1; stuck_start_code=$?
  check "StartWithUndeletableEarlierEvidence_ExitsOne: a started run stops at the same cleanup a plain run does" \
    '[ "$stuck_start_code" -eq 1 ]'
  chmod u+w "$reports/evidence/locked"
fi

if [ "$fails" -eq 0 ]; then echo "verify-evidence: ok"; else echo "verify-evidence: $fails failed"; exit 1; fi
