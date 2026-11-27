#!/bin/sh
# verify-plan-contract.sh: the plan template in the plan skill names a proof in the shape verify
# reads, so a plan written from it as it stands grades its named line live from the named file. A
# named line must be a line of proofs.json: a proofs file that stops short of it fails verify,
# naming plan.md and the line. Each run's gate writes the evidence, as a capture does, and the
# suite writes plan.md and proofs.json alone, never a report. On the local adapter in throwaway
# repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

template_line=2
other_line=1
named_line=2
template_entry=1
template_evidence='evidence/<name>.png'
named_evidence=evidence/score-after-goal.png
named_capture="the replay test ScoreBoard_AfterAGoal_ShowsTheScore"
blocked_reason="the staging server is down"
capture_gate() { printf "  capture: 'sh %s/capture-%s.sh'\n" "$work" "$1"; }
capture_file() { printf "mkdir -p '%s/evidence' && echo png > '%s/%s'\n" "$reports" "$reports" "$2" > "$work/capture-$1.sh"; }
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
blocked_proof() { printf '{"line": %s, "text": "line %s", "grade": "blocked", "reason": "%s"}' "$1" "$1" "$blocked_reason"; }
write_template_plan() { python3 -c 'import re,sys
skill=open(sys.argv[1]).read()
section=skill.split("## 3. The plan template",1)[1]
print(re.search(r"```markdown\n(.*?)\n```", section, re.S).group(1))' "$plugin/skills/plan/SKILL.md" > "$reports/plan.md"; }
check_status() { python3 -c 'import json,sys; print("".join(check["status"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]))' "$reports/verify.json" "$1"; }
check_summary() { python3 -c 'import json,sys; print("".join(check["summary"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]))' "$reports/verify.json" "$1"; }

echo "a plan written from the template"
new_item template "$(capture_gate template)"
capture_file template "$template_evidence"
write_template_plan
write_proofs "[$(blocked_proof "$other_line"), $(blocked_proof "$template_line")]"
verify >/dev/null 2>&1
check "PlanWrittenFromTheTemplate_JsonGradesItsLineLive: the template names a proof in the shape verify reads" \
  '[ "$(json_value "proofs.$template_entry.grade" < "$reports/verify.json")" = live ]'
check "PlanWrittenFromTheTemplate_JsonEvidenceIsTheTemplatesFile: the file the template names is the evidence" \
  '[ "$(json_value "proofs.$template_entry.evidence" < "$reports/verify.json")" = "$template_evidence" ]'

echo "a proofs file that stops short of the named line"
new_item short "$(capture_gate short)"
capture_file short "$named_evidence"
printf '# the score shows\nGoal: the player sees the score.\n\n## Acceptance\n%s. the score shows after a goal\n   Proof: %s by %s\n\n## Phase 1: The score\n- [ ] Draw the score.\n' \
  "$named_line" "$named_evidence" "$named_capture" > "$reports/plan.md"
write_proofs "[$(blocked_proof "$other_line")]"
verify >/dev/null 2>&1
check "ProofsFileShortOfTheNamedLine_ReportSaysFail: a named line past the last line of proofs.json fails verify" \
  '[ "$(report_status)" = fail ]'
check "ProofsFileShortOfTheNamedLine_PlanProofsCheckFails: the plan proofs check is the one that failed" \
  '[ "$(check_status "plan proofs")" = fail ]'
check "ProofsFileShortOfTheNamedLine_CheckSummaryNamesThePlanAndTheLine: the verifier learns which plan line has no proofs entry" \
  'check_summary "plan proofs" | grep -F -- plan.md | grep -qF -- "line $named_line"'

if [ "$fails" -eq 0 ]; then echo "verify-plan-contract: ok"; else echo "verify-plan-contract: $fails failed"; exit 1; fi
