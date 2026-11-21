#!/bin/sh
# graph-report.sh: the graph report scripts/graph-report.sh prints from a run log, on the local
# adapter in a throwaway repo. A step shows its runs, its median time, the time nine runs in ten
# finish within, its failed runs and its runs per item; a step whose median grew by half or more against the period before is named,
# one at the same pace is not; runs outside the period are left out; a period with no run says
# so; a line of the log that is no step record is passed over; a bad --days is refused. The step
# runs of each day are kept in a history file that outlives the cut of the run log: a day once,
# a full day after it ended, with a run that came in after midnight counted, and the runs of the
# days not yet kept carried over every cut; --json carries the report and the daily lines.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

REPORT_NOW="2026-10-25T00:00:00Z"
new_repo graph
mkdir -p .flow/log
# ran <item> <step> <days before the report's time> <seconds> [exit code]: one step record in the run log.
ran() {
  python3 -c 'import json, sys, time, calendar
now = calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ"))
at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - float(sys.argv[4]) * 86400))
print(json.dumps({"item": sys.argv[2], "step": sys.argv[3], "at": at, "seconds": int(sys.argv[5]), "exit": int(sys.argv[6]), "cost_usd": 0.5}))' \
    "$REPORT_NOW" "$1" "$2" "$3" "$4" "${5:-0}" >> .flow/log/runs.jsonl
}
graph_report() { FLOW_NOW="$REPORT_NOW" "$plugin/scripts/graph-report.sh" "$@"; }
# row_of <step>: the step's row of the report's table.
row_of() { graph_report | grep "^| $1 |"; }
in_short_section() { graph_report "$@" | sed -n '/^## In short$/,/^## Steps$/p'; }

echo "graph report: a period with no run"
check "LogWithNoRun_SaysNoStepRan: an empty period is said, never shown as an empty table" \
  'graph_report | grep -q "^No step ran in this period\.$"'

echo "graph report: what a step cost"
ran local:task/1 verify 1 100; ran local:task/1 verify 2 200; ran local:task/2 verify 3 300 1
ran local:task/1 implement 1 60; ran local:task/1 implement 2 60; ran local:task/2 implement 2 60; ran local:task/2 implement 3 60
ran local:task/9 verify 30 9000
printf 'not a record\n{"job":"next","seconds":5}\n' >> .flow/log/runs.jsonl
check "StepWithThreeRuns_ShowsTheMiddleOneAsItsMedian: runs of 100, 200 and 300 seconds have a median of 3m 20s" \
  'row_of verify | grep -q "^| verify | 3 | 3m 20s |"'
check "RunThatEndedNonZero_IsCountedAsFailed: one of the three verify runs failed" \
  '[ "$(row_of verify | cut -d"|" -f6 | tr -d " ")" = 1 ]'
check "StepRunFourTimesOnTwoItems_ShowsTwoRunsPerItem: the reruns per item are what the owner ranks steps by" \
  '[ "$(row_of implement | cut -d"|" -f8 | tr -d " ")" = 2.0 ]'
check "RunOlderThanBothPeriods_IsLeftOut: the 9000 second run of a month ago changes no number" \
  '! graph_report | grep -q "local:task/9"'

echo "graph report: the verdict it opens with"
check "Verdict_ComesBeforeTheTables: the owner reads what stands out before any number" \
  '[ "$(graph_report | grep -n "^## In short$" | cut -d: -f1)" -lt "$(graph_report | grep -n "^## Steps$" | cut -d: -f1)" ]'
check "StepRunTwiceForEachItem_IsNamedAsRepeated: implement ran four times on two items, which is rework" \
  'in_short_section | grep -q "implement ran 2.0 times per item"'
check "StepRunLessThanTwicePerItem_IsNotNamedAsRepeated: verify ran three times on two items" \
  '! in_short_section | grep -q "verify ran"'
check "StepWithAFailedRun_IsNamedWithItsFailedRuns: one of the three verify runs failed" \
  'in_short_section | grep -q "1 of 3 verify runs failed"'
check "StepWithNoFailedRun_IsNotNamedAsFailed: every implement run passed" \
  '! in_short_section | grep -q "implement runs failed"'
check "PeriodWithNothingNotable_SaysNothingStandsOut: in the last day each step ran once and none failed, so the verdict is not left empty" \
  'in_short_section --days 1 | grep -q "Nothing stands out"'

echo "graph report: nine runs in ten"
for seconds in 1 2 3 4 5 6 7 8 9 3600; do ran local:task/5 deliver 4 "$seconds"; done
check "TenRunsWithOneSlowOutlier_ShowTheNinthAsNineInTenWithin: nine of the ten deliver runs end within 9 seconds, the one hour run is the tenth" \
  '[ "$(row_of deliver | cut -d"|" -f5 | tr -d " ")" = 9s ]'

echo "graph report: a step that got slower"
ran local:task/3 review 8 100; ran local:task/3 review 9 100; ran local:task/3 review 10 100
ran local:task/4 review 1 400; ran local:task/4 review 2 400; ran local:task/4 review 3 400
ran local:task/3 plan 8 100; ran local:task/3 plan 9 100; ran local:task/3 plan 10 100
ran local:task/4 plan 1 110; ran local:task/4 plan 2 110; ran local:task/4 plan 3 110
check "StepWhoseMedianGrewFourfold_IsNamedWithBothMedians: review went from 1m 40s to 6m 40s" \
  'graph_report | grep -q "^- review: 1m 40s to 6m 40s at the median, 4.0 times$"'
check "StepAtNearlyTheSamePace_IsNotNamed: ten seconds more is no slowdown" \
  '! graph_report | grep -q "^- plan:"'
check "StepWhoseMedianGrewFourfold_LeadsTheVerdict: a slowdown is the first thing the owner reads" \
  'in_short_section | sed -n 3p | grep -q "review takes 6m 40s at the median, up from 1m 40s"'
check "ItemThatTookTheMostStepTime_IsNamedInTheVerdict: the ten deliver runs of local:task/5 add up to more than any other item" \
  'in_short_section | grep -q "local:task/5 took 1h 00m over 10 step runs"'

echo "graph report: the period"
check "DaysGiven_SetThePeriod: with --days 1 only the runs of the last day count, one verify run" \
  'graph_report --days 1 | grep -q "^| verify | 1 |"'
graph_report --days 0 >/dev/null 2>&1; zero_days_code=$?
check "DaysOfZero_IsRefused: exit 2, a period needs at least one day" '[ "$zero_days_code" -eq 2 ]'

echo "graph report: the history of the steps"
REPORT_NOW="2026-10-25T12:00:00Z"
FINISHED_DAY=2026-10-23; DAY_UNDER_WAY=2026-10-25
new_repo history
mkdir -p .flow/log
history_file=.flow/log/steps.daily.jsonl
ran local:task/1 verify 2 100; ran local:task/1 verify 2 300; ran local:task/2 implement 2 60
ran local:task/1 verify 0.1 500
kept_lines() { cat "$history_file" 2>/dev/null | grep -c "\"day\":\"$1\"" || true; }
daily_value() { graph_report --json | python3 -c 'import json, sys
found = [line[sys.argv[3]] for line in json.load(sys.stdin)["daily"] if (line["day"], line["step"]) == (sys.argv[1], sys.argv[2])]
print(found[0] if found else "")' "$1" "$2" "$3"; }
kept_output="$(graph_report --keep)"
check "KeepOnALogWithAFinishedDay_WritesOneLineForEachStepOfThatDay: verify and implement ran two days ago" \
  '[ "$(kept_lines "$FINISHED_DAY")" = 2 ]'
check "KeepOnALogWithARunToday_KeepsNothingOfTheDayUnderWay: a day is kept once, when it is over" \
  '[ "$(kept_lines "$DAY_UNDER_WAY")" = 0 ]'
check "Keep_PrintsNothing: the job that cuts the log calls it for the file alone" '[ -z "$kept_output" ]'
graph_report --keep; graph_report >/dev/null
check "DayAlreadyKept_IsNotWrittenAgain: every report keeps the finished days first, so a second one must add nothing" \
  '[ "$(kept_lines "$FINISHED_DAY")" = 2 ]'
check "KeptDay_CarriesTheMedianOfItsRuns: the two verify runs of 100 and 300 seconds have a median of 200" \
  '[ "$(daily_value "$FINISHED_DAY" verify median)" = 200 ]'
check "KeptDay_CarriesTheTotalTimeOfItsRuns: 100 and 300 seconds are 400, which a median times the runs would not give for uneven runs" \
  '[ "$(daily_value "$FINISHED_DAY" verify seconds)" = 400 ]'
check "JsonReport_CountsTheDayUnderWayFromTheLog: today's verify run is on the chart before the day is kept" \
  '[ "$(daily_value "$DAY_UNDER_WAY" verify runs)" = 1 ]'
check "JsonReport_CarriesTheReportAsMarkdown: one call gives the console the report and the chart" \
  '[ "$(graph_report --json | python3 -c "import json, sys; print(json.load(sys.stdin)[\"markdown\"])")" = "$(graph_report)" ]'
ran local:task/7 verify 40 900
graph_report --keep
check "DayOlderThanThirtyDays_IsKeptButLeftOffTheDailyLines: the chart shows the last thirty days" \
  '[ "$(kept_lines 2026-09-15)" = 1 ] && [ -z "$(daily_value 2026-09-15 verify runs)" ]'
rm .flow/log/runs.jsonl
check "DayWhoseRunsLeftTheLog_StaysInTheDailyLines: the history is what remains once the log is cut" \
  '[ "$(daily_value "$FINISHED_DAY" verify runs)" = 2 ]'

echo "graph report: a run that ended after midnight is counted on the day it started"
YESTERDAY=2026-10-24
new_repo midnight
mkdir -p .flow/log
ran local:task/1 verify 0.6 100
graph_report --keep
ran local:task/2 verify 0.55 300
check "RunRecordedAfterItsDayEnded_IsCountedOnThatDay: a run is logged when it ends, under the time it started" \
  '[ "$(daily_value "$YESTERDAY" verify runs)" = 2 ]'
check "DayThatEndedLessThanADayAgo_IsNotKeptYet: a run that began before midnight may still be going" \
  '[ "$(kept_lines "$YESTERDAY")" = 0 ]'
REPORT_NOW="2026-10-26T12:00:00Z"
graph_report --keep
check "DayThatEndedAFullDayAgo_IsKeptWithTheRunThatCameLate: both runs are in the one line the day gets" \
  '[ "$(kept_lines "$YESTERDAY")" = 1 ] && [ "$(daily_value "$YESTERDAY" verify runs)" = 2 ]'
REPORT_NOW="2026-10-25T12:00:00Z"

echo "graph report: two reports at once keep a day once"
new_repo together
mkdir -p .flow/log
ran local:task/1 verify 2 100
LOCK_HELD_SECONDS=4; KEEP_HAS_STARTED_SECONDS=2
python3 -c 'import fcntl, sys, time
held = open(sys.argv[1], "w"); fcntl.flock(held, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(float(sys.argv[3]))' \
  .flow/log/steps.daily.lock "$work/lock-is-held" "$LOCK_HELD_SECONDS" &
while [ ! -f "$work/lock-is-held" ]; do sleep 0.1; done
graph_report --keep &
sleep "$KEEP_HAS_STARTED_SECONDS"
check "KeepWhileAnotherWriterHoldsTheHistoryLock_HasWrittenNothing: it waits, or two writers would both find the day missing and write it" \
  '[ "$(kept_lines "$FINISHED_DAY")" = 0 ]'
wait
check "KeepAfterTheOtherWriterLetGo_KeepsTheDay: the wait ends with the day written once" \
  '[ "$(kept_lines "$FINISHED_DAY")" = 1 ]'

echo "graph report: the cut of the run log keeps the history first"
new_repo cut
mkdir -p .flow/log
ran local:task/1 verify 2 100
ran local:task/2 verify 0.1 700
LINES_BEFORE_THE_CUT=3999
fill_the_log_to_one_line_short_of_the_cut() {
  python3 -c 'import os, sys
have = sum(1 for _ in open(sys.argv[1])) if os.path.exists(sys.argv[1]) else 0
with open(sys.argv[1], "a") as log:
    log.write("{\"job\":\"health\",\"seconds\":1}\n" * (int(sys.argv[2]) - have))' .flow/log/runs.jsonl "$LINES_BEFORE_THE_CUT"
}
end_a_job_run_that_writes_its_log_line() { FLOW_NOW="$REPORT_NOW" "$plugin/jobs/health.sh" claude >/dev/null 2>&1; }
fill_the_log_to_one_line_short_of_the_cut; end_a_job_run_that_writes_its_log_line
check "LogAtItsLimit_IsCut: the run log moved aside, or the checks below prove nothing" \
  '[ -f .flow/log/runs.1.jsonl ] && [ ! -s .flow/log/runs.jsonl ]'
fill_the_log_to_one_line_short_of_the_cut; end_a_job_run_that_writes_its_log_line
check "LogCutTwice_HoldsTheStepRunsNoMore: the second cut replaced the file the runs were in" \
  '! grep -q "local:task/" .flow/log/runs.1.jsonl .flow/log/runs.jsonl 2>/dev/null'
check "StepRunOfASettledDayCutFromTheLog_StaysInTheHistory: the cut kept the day before the file went" \
  '[ "$(daily_value "$FINISHED_DAY" verify runs)" = 1 ]'
check "StepRunOfTheDayUnderWayCutFromTheLogTwice_StaysOnTheChart: a day too young to keep is carried over every cut" \
  '[ "$(daily_value "$DAY_UNDER_WAY" verify runs)" = 1 ]'

if [ "$fails" -eq 0 ]; then echo "graph-report: ok"; else echo "graph-report: $fails failed"; exit 1; fi
