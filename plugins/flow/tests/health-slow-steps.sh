#!/bin/sh
# health-slow-steps.sh: the health job says when a step got slower, on the local adapter in
# throwaway repos with a fake Slack destination and fake model hosts. graph-report.sh --slower names the steps the report's
# verdict calls slower, and keeps no history. A health pass says and notifies each such step once,
# with its median now and before; a step that stays slower is not said again, one that recovered
# is said again when it slows down anew. --dry-run says it and records nothing. A project with no
# run log or no runs to compare says nothing; a report that fails is one finding and the pass
# ends as usual. No model runs.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

REPORT_NOW="2026-10-25T00:00:00Z"
SECONDS_PER_DAY=86400
SLACK_HOOK=https://hook.example/flow
SLACK_INBOX="$work/slack-inbox.jsonl"
MODEL_SPEND="$work/model-spend.log"
mkdir -p "$work/destinations"
cat > "$work/destinations/curl" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do
  [ "\$1" != --data ] || printf '%s' "\$2" | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["text"]))' >> "$SLACK_INBOX"
  shift
done
EOF
for model_host in claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$model_host" "$MODEL_SPEND" > "$work/destinations/$model_host"
done
chmod +x "$work/destinations/curl" "$work/destinations/claude" "$work/destinations/codex"
PATH="$work/destinations:$PATH"; export PATH
ran() {
  mkdir -p .flow/log
  python3 -c 'import json, sys, time, calendar
now = calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ"))
at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - float(sys.argv[3]) * int(sys.argv[5])))
print(json.dumps({"item": "local:task/1", "step": sys.argv[2], "at": at, "seconds": int(sys.argv[4]), "exit": 0, "cost_usd": 0.5}))' \
    "$REPORT_NOW" "$1" "$2" "$3" "$SECONDS_PER_DAY" >> .flow/log/runs.jsonl
}
runs_of() { runs_step="$1"; runs_seconds="$2"; shift 2; for runs_day in "$@"; do ran "$runs_step" "$runs_day" "$runs_seconds"; done; }
review_got_slower() { runs_of review 100 8 9 10; runs_of review 400 1 2 3; }
plan_kept_its_pace() { runs_of plan 100 8 9 10; runs_of plan 110 1 2 3; }
health_pass() {
  health_output="$1"; shift
  FLOW_NOW="${HEALTH_NOW:-$REPORT_NOW}" FLOW_SLACK_WEBHOOK="$SLACK_HOOK" "$plugin/scripts/steward.sh" health "$@" > "$health_output" 2>&1
  echo "$?" > "$health_output.code"
}
slower_findings() { grep -c "got slower" "$1" || true; }
messages_received() { cat "$SLACK_INBOX" 2>/dev/null | grep -c . || true; }
events_said() { cat .flow/events.log 2>/dev/null | grep -c "got slower" || true; }

echo "health slow steps: the report names the slower steps"
new_repo report
review_got_slower; plan_kept_its_pace
slower_output="$(FLOW_NOW="$REPORT_NOW" "$plugin/scripts/graph-report.sh" --slower)"
check "SlowerOutputOnALogWithASettledDay_KeepsNoHistory: the health job asks it every pass, so it must write nothing" \
  '[ ! -e .flow/log/steps.daily.jsonl ] && [ ! -e .flow/log/steps.pending.jsonl ]'
verdict_slower="$(FLOW_NOW="$REPORT_NOW" "$plugin/scripts/graph-report.sh" | grep -c '^- \*\*Slower:\*\*')"
check "SlowerOutput_HasOneLinePerSlowerLineOfTheVerdict: the health job and the report share one rule" \
  '[ "$(printf "%s\n" "$slower_output" | grep -c .)" = "$verdict_slower" ]'
check "SlowerOutput_GivesTheStepAndBothMediansApartByTabs: review went from 1m 40s to 6m 40s, which a shell reads with no parsing of prose" \
  '[ "$slower_output" = "$(printf "review\t6m 40s\t1m 40s")" ]'

echo "health slow steps: a pass says a slower step once"
health_pass "$work/first.out"
check "StepTheReportNamesAsSlower_IsSaidWithItsMedianNowAndBefore: the owner learns which step and by how much without opening the report" \
  'grep -q "the step review got slower: its median run took 6m 40s in the last 7 days, up from 1m 40s" "$work/first.out"'
check "StepAtNearlyTheSamePace_IsNotSaid: ten seconds more is no slowdown to the report, so not to the health job" \
  '! grep -q "plan got slower" "$work/first.out"'
check "StepTheReportNamesAsSlower_IsNotifiedToTheOwner: the owner hears of it without reading the health log" \
  '[ "$(messages_received)" = 1 ] && grep -q "review got slower: its median run took 6m 40s" "$SLACK_INBOX"'
check "StepTheReportNamesAsSlower_IsLoggedInEvents: the board reads the findings from events.log" \
  '[ "$(events_said)" = 1 ]'
check "HealthPassWithASlowerStep_SpendsNoModel: the job runs every few minutes, so only a report is read" \
  '[ ! -s "$MODEL_SPEND" ]'
health_pass "$work/second.out"
check "StepStillSlowerOnTheNextPass_IsNotSaidAgain: a finding is said once per change, not every pass" \
  '[ "$(slower_findings "$work/second.out")" = 0 ]'
check "StepStillSlowerOnTheNextPass_IsNotNotifiedAgain: the owner was told once already" \
  '[ "$(messages_received)" = 1 ]'

echo "health slow steps: a step that recovered and slowed down again"
runs_of review 100 1 2 3 4
health_pass "$work/recovered.out"
check "StepNoLongerSlower_IsNotSaid: four fast runs bring the median back to 1m 40s" \
  '[ "$(slower_findings "$work/recovered.out")" = 0 ]'
runs_of review 900 1 2 3 4 5 6
health_pass "$work/again.out"
check "StepSlowerAgainAfterItRecovered_IsSaidAgain: the recovery forgot the first slowdown, so the new one is news" \
  'grep -q "the step review got slower" "$work/again.out"'
check "StepSlowerAgainAfterItRecovered_IsNotifiedAgain: the owner hears of the new slowdown too" \
  '[ "$(messages_received)" = 2 ]'

echo "health slow steps: --dry-run"
new_repo dry
: > "$SLACK_INBOX"
review_got_slower
health_pass "$work/dry.out" --dry-run
check "DryRunWithASlowerStep_SaysTheFinding: a dry run shows what a pass would find" \
  'grep -q "the step review got slower" "$work/dry.out"'
check "DryRunWithASlowerStep_SaysItWouldNotify: the notification it would send is shown, not sent" \
  'grep -q "^would notify: The step review got slower" "$work/dry.out"'
check "DryRunWithASlowerStep_SendsNoNotification: a dry run changes nothing the owner sees" \
  '[ "$(messages_received)" = 0 ]'
check "DryRunWithASlowerStep_WritesNoEventsLine: a dry run records nothing" \
  '[ "$(events_said)" = 0 ]'
check "DryRunWithASlowerStep_KeepsNoStepHistory: a dry run records nothing, the history of the steps included" \
  '[ ! -e .flow/log/steps.daily.jsonl ] && [ ! -e .flow/log/steps.pending.jsonl ]'
health_pass "$work/after-dry.out"
check "PassAfterADryRun_StillSaysTheSlowerStep: the dry run recorded nothing that would mark the finding as said" \
  'grep -q "the step review got slower" "$work/after-dry.out"'

echo "health slow steps: nothing to compare"
new_repo empty
health_pass "$work/no-log.out"
check "ProjectWithNoRunLog_SaysNothingOfSlowerSteps: no run, no slowdown and no failed report" \
  '! grep -q "got slower\|graph report" "$work/no-log.out"'
new_repo young
runs_of review 400 1 2 3
health_pass "$work/no-history.out"
check "ProjectWithNoRunsBeforeThisPeriod_SaysNothingOfSlowerSteps: a step with no earlier runs has nothing to be slower than" \
  '! grep -q "got slower\|graph report" "$work/no-history.out"'

echo "health slow steps: a report that fails"
new_repo failing
review_got_slower
HEALTH_NOW="not-a-time" health_pass "$work/failed.out"
check "ReportThatFails_IsOneFinding: the owner learns the report broke, not that nothing is slower" \
  '[ "$(grep -c "the graph report failed" "$work/failed.out")" = 1 ]'
check "ReportThatFails_SaysWhyItFailed: the report's own error is in the finding" \
  'grep "the graph report failed" "$work/failed.out" | grep -q "not-a-time is no ISO time"'
check "ReportThatFails_LetsThePassEndWithItsSummary: the rest of the health pass still runs" \
  '[ "$(cat "$work/failed.out.code")" = 0 ] && tail -n 1 "$work/failed.out" | grep -q "^health: "'
HEALTH_NOW="not-a-time" health_pass "$work/failed-again.out"
check "ReportThatFailsTheSameWayAgain_IsNotSaidAgain: a failure that stays is said once" \
  '! grep -q "the graph report failed" "$work/failed-again.out"'

if [ "$fails" -eq 0 ]; then echo "health-slow-steps: ok"; else echo "health-slow-steps: $fails failed"; exit 1; fi
