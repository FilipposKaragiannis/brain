#!/bin/sh
# gate-from-step.sh: the gate record names the step it came from, on the local adapter in
# throwaway repos. A step that fails its last attempt raises an escalation whose listed gate
# carries that step, verify apart from any other, and a record an older plugin wrote, with no
# step, lists null.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

max_attempts="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_attempts"])' "$plugin/profiles.json")"
escalated_at() {
  escalated_item="$(new_task "$1")"
  "$local_adapter/write-state.sh" "$escalated_item" "step=$2" profile=task-S "attempts=$((max_attempts - 1))" >/dev/null
  start_step "$escalated_item"
  step_result "$escalated_item" "$2" '{"status":"fail","summary":"A check stayed red."}'
  finish_step "$escalated_item"
  printf '%s' "$escalated_item"
}
listed_from_step() {
  "$plugin/scripts/gate.sh" list --json | python3 -c 'import json,sys
gates = [gate for gate in json.load(sys.stdin) if gate["item"] == sys.argv[1]]
print(json.dumps(gates[0]["from_step"]) if len(gates) == 1 else "no single gate for " + sys.argv[1])' "$1"
}

echo "gate from step: an escalation names the step that failed"
new_repo escalations
verify_escalated="$(escalated_at "Verify stays red" verify)"
review_escalated="$(escalated_at "Review keeps finding gaps" review)"
check "VerifyFailsItsLastAttempt_ListedGateNamesVerify: the console tells a verify escalation by its from_step" \
  '[ "$(listed_from_step "$verify_escalated")" = "\"verify\"" ]'
check "ReviewFailsItsLastAttempt_ListedGateNamesReview: an escalation from another step is not taken for a verify one" \
  '[ "$(listed_from_step "$review_escalated")" = "\"review\"" ]'

echo "gate from step: a record from an older plugin"
older_item="$(new_task "Gated before the step was recorded")"
printf '{"gate":"escalation","item":"%s","message":"Step verify failed 3 times.","time":"2026-10-24T09:00:00Z","host":"shell"}\n' \
  "$older_item" > ".flow/gates/$(slug "$older_item").json"
check "RecordWithNoStep_ListedFromStepIsNull: a record an older plugin wrote lists, with no step to name" \
  '[ "$(listed_from_step "$older_item")" = null ]'

[ "$fails" -eq 0 ] && { echo "gate-from-step: ok"; exit 0; }
echo "gate-from-step: $fails failed"; exit 1
