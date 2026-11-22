#!/bin/sh
# gate-transition.sh: an item never moves past a human gate the tracker has not recorded, on the
# local adapter with a stand-in write-state that refuses or dies on the write that records a gate,
# and on the GitHub adapter with the fake gh. advance.sh moves the step and records the gate in
# one tracker write; a refused or killed write leaves the item at its step with its run, exits 1
# with the reason, and a retry raises the gate once. A failing notifier leaves the gate standing
# and says so. next.sh runs no step for an item with a gate record on this host that its tracker
# does not show.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

stubbed="$work/plugin-stubbed"; cp -R "$plugin" "$stubbed"; rm -rf "$stubbed/evals/results"
mv "$stubbed/adapters/local/write-state.sh" "$stubbed/adapters/local/write-state-tracker.sh"
GATE_WRITE_MODE="$work/gate-write-mode"; export GATE_WRITE_MODE
cat > "$stubbed/adapters/local/write-state.sh" <<'STUB'
#!/bin/sh
for pair in "$@"; do
  case "$pair" in
    gate=|gate=none) ;;
    gate=*)
      case "$(cat "$GATE_WRITE_MODE" 2>/dev/null)" in
        refused) echo "flow: the tracker refused the write: API rate limit exceeded" >&2; exit 1 ;;
        killed) kill -9 "$$" ;;
      esac ;;
  esac
done
exec "$(dirname "$0")/write-state-tracker.sh" "$@"
STUB
chmod +x "$stubbed/adapters/local/write-state.sh"
FLOW_PLUGIN="$stubbed"; export FLOW_PLUGIN
local_adapter="$stubbed/adapters/local"

export FAKE_GH_DIR="$work/gh" FLOW_GH_RETRY_WAIT="0 0"
mkdir -p "$FAKE_GH_DIR" "$work/github" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$plugin/tests/fake-gh.sh" "$work/github/gh"
PATH="$work/github:$PATH"; export PATH

PLAN_SUMMARY="Plan: one module, two steps."
item_file() { printf '.flow/items/task/%s.md' "${1##*/}"; }
gate_comments() { grep -c '\*\*Gate: plan-approval\*\*' "$(item_file "$1")"; }
gate_record() { printf '.flow/gates/%s.json' "$(slug "$1")"; }
reports_of() { json_value reports < "$(run_file "$1")"; }
planned_task() {
  planned="$(new_task "$1")"
  "$local_adapter/write-state.sh" "$planned" step=plan profile=task-M size=M
  "$stubbed/scripts/next.sh" "$planned" >/dev/null 2>&1
  printf '%s\n' "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}" > "$(reports_of "$planned")/plan.json"
  printf '%s' "$planned"
}
advance() { "$stubbed/scripts/advance.sh" "$1" > "$work/advance.out" 2> "$work/advance.err"; }

echo "gate transition: the tracker refuses the gate write"
new_repo refused
refused="$(planned_task "Refused gate")"; refused_reports="$(reports_of "$refused")"
echo refused > "$GATE_WRITE_MODE"
advance "$refused"; refused_code=$?
check "RefusedGateWrite_ExitsWithAFailureThatIsNotTheGateWait: the caller must not report the item as waiting at a gate" \
  '[ "$refused_code" -ne 0 ] && [ "$refused_code" -ne 4 ]'
check "RefusedGateWrite_NamesTheReason: the owner reads why no gate was raised" \
  'grep -q "rate limit" "$work/advance.err" && grep -q "plan-approval gate on $refused is not recorded" "$work/advance.err"'
check "RefusedGateWrite_LeavesTheItemAtThePlanStep: no reader sees the step past an unrecorded gate" \
  '[ "$(state "$refused" step)" = plan ] && [ "$(state "$refused" gate)" = none ]'
check "RefusedGateWrite_KeepsTheRun: advance.sh run again picks the gate transition up" \
  '[ -f "$(run_file "$refused")" ]'
check "RefusedGateWrite_RecordsNoGateOnThisHost: the owner is not asked a question the tracker does not hold" \
  '[ ! -e "$(gate_record "$refused")" ]'
"$stubbed/scripts/next.sh" "$refused" >/dev/null 2>&1; refused_next_code=$?
check "RefusedGateWrite_NextStartsNoImplementStep: the plan is not approved" \
  '[ "$refused_next_code" -ne 0 ] && [ ! -e "$refused_reports/brief-implement.md" ]'

echo "gate transition: a retry after the refusal"
rm -f "$GATE_WRITE_MODE"
advance "$refused"; retry_code=$?
check "RetryAfterARefusedGateWrite_WaitsAtTheGate: the transition the refusal stopped completes" \
  '[ "$retry_code" -eq 4 ] && [ "$(state "$refused" gate)" = plan-approval ] && [ "$(state "$refused" step)" = implement ]'
check "RetryAfterARefusedGateWrite_RaisesOneGateComment: the owner is asked once" \
  '[ "$(gate_comments "$refused")" -eq 1 ]'
check "RetryAfterARefusedGateWrite_WritesOneGateRecord: the board lists the gate once" \
  '[ "$(ls .flow/gates | wc -l | tr -d " ")" -eq 1 ] && [ "$(json_value gate < "$(gate_record "$refused")")" = plan-approval ]'
"$stubbed/scripts/next.sh" "$refused" >/dev/null 2>&1; retry_next_code=$?
check "RetryAfterARefusedGateWrite_NextWaitsAtTheGate: implement waits for the approval" \
  '[ "$retry_next_code" -eq 4 ] && [ ! -e "$refused_reports/brief-implement.md" ]'

echo "gate transition: the gate write dies"
new_repo killed
killed="$(planned_task "Killed gate")"; killed_reports="$(reports_of "$killed")"
echo killed > "$GATE_WRITE_MODE"
advance "$killed"; killed_code=$?
rm -f "$GATE_WRITE_MODE"
check "KilledGateWrite_ExitsWithAFailureThatIsNotTheGateWait: a write that died recorded nothing" \
  '[ "$killed_code" -ne 0 ] && [ "$killed_code" -ne 4 ]'
check "KilledGateWrite_LeavesTheItemAtThePlanStep: the step and the gate land together or not at all" \
  '[ "$(state "$killed" step)" = plan ] && [ "$(state "$killed" gate)" = none ] && [ -f "$(run_file "$killed")" ]'
"$stubbed/scripts/next.sh" "$killed" >/dev/null 2>&1; killed_next_code=$?
check "KilledGateWrite_NextStartsNoImplementStep: the plan is not approved" \
  '[ "$killed_next_code" -ne 0 ] && [ ! -e "$killed_reports/brief-implement.md" ]'

echo "gate transition: the desktop notification fails"
new_repo notifier
sed -i.bak 's/desktop: false/desktop: true/' .flow/config.yaml && rm -f .flow/config.yaml.bak
mkdir -p "$work/broken" && printf '#!/bin/sh\nexit 1\n' > "$work/broken/osascript" && chmod +x "$work/broken/osascript"
notified="$(planned_task "Notifier down")"
PATH="$work/broken:$PATH" advance "$notified"; notified_code=$?
check "FailingNotifier_LeavesTheGateRecorded: a notification is no part of the gate" \
  '[ "$notified_code" -eq 4 ] && [ "$(state "$notified" gate)" = plan-approval ] && [ -f "$(gate_record "$notified")" ]'
check "FailingNotifier_IsReported: the owner learns no notification went out" \
  'grep -q "desktop notification failed" "$work/advance.err"'

echo "gate transition: the normal path"
new_repo normal
normal="$(planned_task "Normal gate")"
advance "$normal"; normal_code=$?
check "PlanDone_WaitsAtThePlanApprovalGateWithStatusFour: the owner approves before implement" \
  '[ "$normal_code" -eq 4 ] && [ "$(state "$normal" gate)" = plan-approval ] && [ "$(state "$normal" step)" = implement ]'

echo "gate transition: a gate record the tracker does not show"
stray="$(new_task "Stray record")"
"$local_adapter/write-state.sh" "$stray" step=implement profile=task-M size=M
printf '{"gate": "plan-approval", "item": "%s", "message": "Approve the plan."}' "$stray" > "$(gate_record "$stray")"
"$stubbed/scripts/next.sh" "$stray" > "$work/stray.out" 2> "$work/stray.err"; stray_code=$?
check "GateRecordTheTrackerLacks_StopsNextAtTheGate: the owner was asked, so the step waits for the answer" \
  '[ "$stray_code" -eq 4 ] && [ ! -f "$(run_file "$stray")" ]'
check "GateRecordTheTrackerLacks_SaysWhy: the owner learns which record holds the item and how to answer" \
  'grep -q "plan-approval gate recorded on this host" "$work/stray.err" && grep -q "gate.sh clear $stray" "$work/stray.err"'

echo "gate transition: GitHub refuses the gate labels"
new_repo github
sed -i.bak 's/^  default: local$/  default: github/' .flow/config.yaml && rm -f .flow/config.yaml.bak
printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/1"}]}\n' > "$FAKE_GH_DIR/issues.json"
tracked="$("$stubbed/adapters/github/create.sh" task "Tracked gate" --size M --body "$body")"
"$stubbed/adapters/github/write-state.sh" "$tracked" step=plan profile=task-M size=M
"$stubbed/scripts/next.sh" "$tracked" >/dev/null 2>&1
printf '%s\n' "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}" > "$(reports_of "$tracked")/plan.json"
refused_label_edits=9
printf '%s\nAPI rate limit exceeded\nissue edit\n' "$refused_label_edits" > "$FAKE_GH_DIR/fail"
advance "$tracked"; tracked_code=$?
rm -f "$FAKE_GH_DIR/fail"
tracked_state() { "$stubbed/adapters/github/read.sh" "$tracked" | json_value "state.$1"; }
check "GitHubRefusedGateLabels_LeavesTheIssueAtThePlanStep: no reader sees implement without the gate" \
  '[ "$tracked_code" -ne 0 ] && [ "$tracked_code" -ne 4 ] && [ "$(tracked_state step)" = plan ] && [ "$(tracked_state gate)" = none ]'
advance "$tracked"; tracked_retry_code=$?
check "GitHubRetryAfterARefusal_WaitsAtTheGate: the retry records the step and the gate" \
  '[ "$tracked_retry_code" -eq 4 ] && [ "$(tracked_state step)" = implement ] && [ "$(tracked_state gate)" = plan-approval ]'

[ "$fails" -eq 0 ] && echo "gate-transition: all passed" || echo "gate-transition: $fails failed"
[ "$fails" -eq 0 ]
