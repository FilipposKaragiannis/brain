#!/bin/sh
# verify-plan-proofs.sh: verify grades a line the plan names in its Acceptance section, with
# `Proof: <path> by <capture>`, live from the plan's file when that file holds: the plan's path is
# the evidence, its capture is carried, and the line counts as proven, whatever grade or file the
# verifier wrote for it and whichever commit its proofs file was written for. Each run's gate
# writes the evidence, as a capture does, and the suite writes plan.md and proofs.json alone,
# never a report. On the local adapter in throwaway repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

other_line=1
named_line=2
lines_proven_by_the_plan=1
named_entry=1
named_text="the score shows after a goal"
named_evidence=evidence/score-after-goal.png
named_capture="the replay test ScoreBoard_AfterAGoal_ShowsTheScore"
verifier_evidence=evidence/never-captured.png
blocked_reason="the staging server is down"
capture_gate() { printf "  capture: 'sh %s/capture-%s.sh'\n" "$work" "$1"; }
write_capture() { printf '%s\n' "$2" > "$work/capture-$1.sh"; }
capture_named_file() { write_capture "$1" "mkdir -p '$reports/evidence' && echo png > '$reports/$named_evidence'"; }
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
write_plan() {
  printf '# %s: the score shows\nGoal: the player sees the score.\n\n## Acceptance\n%s. %s\n   Proof: %s by %s\n\n## Phase 1: The score\n- [ ] Draw the score.\n' \
    "$item" "$named_line" "$named_text" "$named_evidence" "$named_capture" > "$reports/plan.md"
}
report_value() { json_value "$1" < "$reports/verify.json"; }
json_proof_grades() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (proof["line"], proof["grade"]) for proof in json.load(open(sys.argv[1]))["proofs"]))' "$reports/verify.json"; }
json_not_checked_grades() { python3 -c 'import json,sys; print(" ".join("%s:%s" % (entry["line"], entry["grade"]) for entry in json.load(open(sys.argv[1]))["not_checked"]))' "$reports/verify.json"; }

echo "a named file that holds"
new_item holds "$(capture_gate holds)"
capture_named_file holds
write_plan
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

echo "the verifier wrote another grade for the named line"
new_item overridden "$(capture_gate overridden)"
capture_named_file overridden
write_plan
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
write_plan
write_proofs "[{\"line\": $other_line, \"text\": \"the client builds\", \"grade\": \"blocked\", \"reason\": \"$blocked_reason\"},
  {\"line\": $named_line, \"text\": \"$named_text\", \"grade\": \"live\", \"evidence\": \"$verifier_evidence\"}]"
printf 'y\n' > "$worktree/later.txt" && git -C "$worktree" add -A && git -C "$worktree" commit -qm later
verify >/dev/null 2>&1
check "StaleProofsFileWithANamedLine_JsonGradesTheNamedLineLive: the named file is captured in this run, so the head of the proofs file never touches it" \
  '[ "$(report_value proofs.$named_entry.grade)" = live ]'
check "StaleProofsFileWithANamedLine_JsonGradesTheOtherLinesErrors: a line the plan does not name still needs a proofs file of this commit" \
  '[ "$(json_not_checked_grades)" = "$other_line:error" ]'

if [ "$fails" -eq 0 ]; then echo "verify-plan-proofs: ok"; else echo "verify-plan-proofs: $fails failed"; exit 1; fi
