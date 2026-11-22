#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tools="$root/tools"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

. "$here/_flow_project_fixture.sh"
lane_hold_seconds=1; hang_ticks=300; child_seconds=120

cat > "$suite/sessions.sh" <<STUB
echo "  ok   Stub_FirstCheckHolds"
sleep $child_seconds &
echo \$! > "$work/child"
ticks=0
while [ "\$ticks" -lt $hang_ticks ]; do echo tick >> "$work/ticks"; sleep $poll_seconds; ticks=\$((ticks + 1)); done
STUB
python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
ticks=0; until [ -f "$work/ticks" ] || [ "$ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; ticks=$((ticks + 1)); done
kill -TERM "$runner"
runner_state="$(process_state "$runner")"
ticks_at_stop="$(wc -l < "$work/ticks")"; sleep "$lane_hold_seconds"
wait "$runner" || true
child_state="$(process_state "$(cat "$work/child")")"
expect 'RunnerGivenTerm_EndsWhileItsSuiteHangs because a hung suite must not block cancellation' "$runner_state" ended
expect 'RunnerGivenTerm_StopsItsRunningSuite because a stopped run leaves no suite behind' "$(wc -l < "$work/ticks")" "$ticks_at_stop"
expect 'RunnerGivenTerm_EndsTheChildCommandsOfItsSuite because a stopped run leaves no check behind' "$child_state" ended
expect 'RunnerGivenTerm_NamesTheStoppedSuite because the owner must see where the run stood' "$(grep -cx 'flow: sessions stopped' "$work/output")" 1
rm "$work/ticks" "$work/child"
git restore plugins/flow/tests/sessions.sh
stop_grace_seconds=2; stop_margin_seconds=3; cleanup_seconds=1; signal_exit_base=128
cat > "$suite/sessions.sh" <<STUB
trap '' TERM
echo "  ok   Stub_DeafToTerm"
echo \$\$ > "$work/deaf-suite"
: > "$work/deaf-suite-ready"
sleep $child_seconds
STUB
cat > "$suite/base-claim.sh" <<STUB
sh -c 'trap "" TERM; echo \$\$ > "$work/deaf-descendant"; : > "$work/deaf-descendant-ready"; exec sleep $child_seconds' &
sleep $child_seconds
STUB
cat > "$suite/verify-scope.sh" <<STUB
(trap 'sleep $cleanup_seconds; echo cleaned > "$work/cleanup"; exit 0' TERM; : > "$work/cleaning-suite-ready"; sleep $child_seconds) &
sleep $child_seconds
STUB
all_ready() { for ready in deaf-suite-ready deaf-descendant-ready cleaning-suite-ready; do [ -f "$work/$ready" ] || return 1; done; }
FLOW_SUITE_STOP_GRACE_SECONDS="$stop_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
ticks=0; until all_ready || [ "$ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; ticks=$((ticks + 1)); done
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(process_state "$runner")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code=0; else runner_code=$?; fi
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_EndsWithinTheGraceTime because a suite deaf to TERM must not hold up cancellation' "$(if [ "$runner_state" = ended ] && [ "$runner_seconds" -le "$((stop_grace_seconds + stop_margin_seconds))" ]; then echo within-grace; else echo "$runner_state after ${runner_seconds}s"; fi)" within-grace
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_EndsThatSuite because a stopped run leaves no suite behind' "$(process_state "$(cat "$work/deaf-suite")")" ended
expect 'RunnerGivenTermWhileADescendantIgnoresTerm_EndsThatDescendant because a stopped run leaves no check behind' "$(process_state "$(cat "$work/deaf-descendant")")" ended
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped' "$runner_code" "$((signal_exit_base + $(kill -l TERM)))"
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_NamesThatSuiteAsStopped because the owner must see where the run stood' "$(grep -cx 'flow: sessions stopped' "$work/output")" 1
expect 'RunnerGivenTermWhileASuiteCleansUp_LetsItFinishItsCleanup because the grace time lasts until the whole group is gone' "$(cat "$work/cleanup" 2>/dev/null)" cleaned
rm "$work/deaf-suite" "$work/deaf-suite-ready" "$work/deaf-descendant" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready" "$work/cleanup"
git restore plugins/flow/tests/sessions.sh plugins/flow/tests/base-claim.sh plugins/flow/tests/verify-scope.sh
later_signal_seconds=3; many_stop_grace_seconds=4; one_grace_margin_seconds=2; late_start_grace_seconds=5; ticks_per_second=10
verify_stop_grace_seconds="$(FLOW_PLUGIN="$root/plugins/flow"; . "$root/plugins/flow/lib/verify.sh"; echo "$VERIFY_STOP_GRACE")"
write_deaf_suites() {
  for deaf_name in sessions base-claim verify-scope; do
    cat > "$suite/$deaf_name.sh" <<STUB
trap '' TERM
echo \$\$ > "$work/deaf-$deaf_name"
: > "$work/deaf-$deaf_name-ready"
sleep $child_seconds
STUB
  done
}
all_deaf_ready() { for deaf_name in sessions base-claim verify-scope; do [ -f "$work/deaf-$deaf_name-ready" ] || return 1; done; }
deaf_states() { for deaf_name in sessions base-claim verify-scope; do process_state "$(cat "$work/deaf-$deaf_name")"; done | tr '\n' ' ' | sed 's/ $//'; }
stop_runner_of_deaf_suites() {
  write_deaf_suites
  env ${1:+"FLOW_SUITE_STOP_GRACE_SECONDS=$1"} python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
  deaf_runner=$!
  deaf_ready_ticks=0; until all_deaf_ready || [ "$deaf_ready_ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; deaf_ready_ticks=$((deaf_ready_ticks + 1)); done
  kill -"$2" "$deaf_runner"; deaf_stop_sent_at="$(date +%s)"; shift 2
  if [ "$#" -gt 0 ]; then sleep "$later_signal_seconds"; for deaf_later_signal in "$@"; do kill -"$deaf_later_signal" "$deaf_runner" 2> /dev/null || true; done; fi
  deaf_end_ticks=0; while process_running "$deaf_runner" && [ "$deaf_end_ticks" -lt "$((verify_stop_grace_seconds * ticks_per_second))" ]; do sleep "$poll_seconds"; deaf_end_ticks=$((deaf_end_ticks + 1)); done
  deaf_runner_state="$(process_state "$deaf_runner")"; deaf_runner_seconds="$(($(date +%s) - deaf_stop_sent_at))"
  if wait "$deaf_runner"; then deaf_runner_code=0; else deaf_runner_code=$?; fi
}
forget_deaf_suites() { for deaf_name in sessions base-claim verify-scope; do rm "$work/deaf-$deaf_name" "$work/deaf-$deaf_name-ready"; done; git restore plugins/flow/tests/sessions.sh plugins/flow/tests/base-claim.sh plugins/flow/tests/verify-scope.sh; }
within_one_grace() { if [ "$deaf_runner_state" = ended ] && [ "$deaf_runner_seconds" -le "$((many_stop_grace_seconds + one_grace_margin_seconds))" ]; then echo within-grace; else echo "$deaf_runner_state after ${deaf_runner_seconds}s"; fi; }
stop_runner_of_deaf_suites "$many_stop_grace_seconds" INT
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsWithinOneGraceTime because all running suites share one grace time and not one each' "$(within_one_grace)" within-grace
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_states)" 'ended ended ended'
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see which signal stopped the run' "$deaf_runner_code" "$((signal_exit_base + $(kill -l INT)))"
forget_deaf_suites
stop_runner_of_deaf_suites "$many_stop_grace_seconds" HUP TERM INT
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsWithinOneGraceTime because a later signal must not restart or lengthen the wait' "$(within_one_grace)" within-grace
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_ExitsWith128PlusTheFirstSignalNumber because a later signal must not stop the run a second time' "$deaf_runner_code" "$((signal_exit_base + $(kill -l HUP)))"
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_PrintsNoTraceback because a signal must not raise from inside the handler' "$(grep -c Traceback "$work/output")" 0
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_states)" 'ended ended ended'
forget_deaf_suites
stop_runner_of_deaf_suites '' TERM
expect 'RunnerGivenTermWithTheDefaultGrace_EndsBeforeVerifyKillsIt because verify kills only the runner and each suite runs in a session of its own' "$(if [ "$deaf_runner_state" = ended ] && [ "$deaf_runner_seconds" -lt "$verify_stop_grace_seconds" ]; then echo before-verify; else echo "$deaf_runner_state after ${deaf_runner_seconds}s"; fi)" before-verify
expect 'RunnerGivenTermWithTheDefaultGrace_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_states)" 'ended ended ended'
forget_deaf_suites
cat > "$work/late-start-runner.py" <<'PY'
import signal
import sys
import threading
import time
from pathlib import Path
sys.path.append(sys.argv[1])
import flow_clock
import flow_process_groups
import flow_selection
import flow_suites

AWAIT_LIMIT_SECONDS = 30
LATE_START_LINE = "flow: late started"


class ClockThatTellsWhenTheStopIsUnderWay:
    def __init__(self) -> None:
        self.stop_under_way = threading.Event()

    def now(self) -> flow_clock.Instant:
        if threading.current_thread() is threading.main_thread():
            self.stop_under_way.set()
        return flow_clock.Instant(time.monotonic())

    def sleep(self, duration: flow_clock.Duration) -> None:
        time.sleep(duration.seconds)


class OutputThatStopsTheRunAsTheLateSuiteStarts:
    def __init__(self, output, stop_under_way: threading.Event) -> None:
        self.output = output
        self.buffer = output.buffer
        self.stop_under_way = stop_under_way

    def write(self, text: str) -> int:
        self.output.write(text)
        if text == LATE_START_LINE:
            self.output.flush()
            signal.pthread_kill(threading.main_thread().ident, signal.SIGTERM)
            self.stop_under_way.wait(AWAIT_LIMIT_SECONDS)
        return len(text)

    def flush(self) -> None:
        self.output.flush()


first_script, late_script, logs, grace = sys.argv[2:]
clock = ClockThatTellsWhenTheStopIsUnderWay()
sys.stdout = OutputThatStopsTheRunAsTheLateSuiteStarts(sys.stdout, clock.stop_under_way)
settings = flow_suites.settings_from({"FLOW_SUITE_LANES": "1", "FLOW_SUITE_STOP_GRACE_SECONDS": grace}, clock, flow_process_groups.PROCESS_TABLE)
suites = {flow_selection.SuiteName("first"): flow_selection.SuiteCommand(Path(first_script), None), flow_selection.SuiteName("late"): flow_selection.SuiteCommand(Path(late_script), None)}
sys.exit(flow_suites.report_run(flow_suites.run_selected(suites, flow_suites.SuiteLogs(Path(logs)), settings)))
PY
printf 'sleep %s\n' "$lane_hold_seconds" > "$work/first-suite.sh"
printf 'trap "" TERM\necho $$ > "%s"\nsleep %s\n' "$work/late-suite" "$child_seconds" > "$work/late-suite.sh"
mkdir "$work/late-logs"
python3 -I -B "$work/late-start-runner.py" "$project/tools/lib" "$work/first-suite.sh" "$work/late-suite.sh" "$work/late-logs" "$late_start_grace_seconds" > "$work/output" 2>&1 &
late_runner=$!; late_started_at="$(date +%s)"
late_runner_state="$(process_state "$late_runner")"; late_runner_seconds="$(($(date +%s) - late_started_at))"
if wait "$late_runner"; then late_runner_code=0; else late_runner_code=$?; fi
expect 'SuiteALaneStartsAfterTheStop_EndsTheRunWithoutAGraceTime because the runner must not wait on a suite it never let run' "$(if [ "$late_runner_state" = ended ] && [ "$late_runner_seconds" -lt "$((lane_hold_seconds + late_start_grace_seconds))" ]; then echo at-once; else echo "$late_runner_state after ${late_runner_seconds}s"; fi)" at-once
expect 'SuiteALaneStartsAfterTheStop_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped' "$late_runner_code" "$((signal_exit_base + $(kill -l TERM)))"
expect 'SuiteALaneStartsAfterTheStop_LeavesNoProcessBehind because a stopped run leaves no suite behind' "$(if [ -f "$work/late-suite" ]; then process_state "$(cat "$work/late-suite")"; else echo ended; fi)" ended
rm -r "$work/late-start-runner.py" "$work/first-suite.sh" "$work/late-suite.sh" "$work/late-logs"; rm -f "$work/late-suite"
cat > "$work/early-stop-runner.py" <<'PY'
import signal
import sys
import threading
from pathlib import Path
sys.path.append(sys.argv[1])
import flow_clock
import flow_process_groups
import flow_selection
import flow_suites

start_of_a_thread = threading.Thread.start


def start_a_lane_then_stop_the_run(lane: threading.Thread) -> None:
    start_of_a_thread(lane)
    signal.raise_signal(signal.SIGTERM)


threading.Thread.start = start_a_lane_then_stop_the_run
early_script, logs = sys.argv[2:]
settings = flow_suites.settings_from({}, flow_clock.SystemClock(), flow_process_groups.PROCESS_TABLE)
suites = {flow_selection.SuiteName("early"): flow_selection.SuiteCommand(Path(early_script), None)}
sys.exit(flow_suites.report_run(flow_suites.run_selected(suites, flow_suites.SuiteLogs(Path(logs)), settings)))
PY
printf 'echo $$ > "%s"\nsleep %s\n' "$work/early-suite" "$child_seconds" > "$work/early-suite.sh"
mkdir "$work/early-logs"
python3 -I -B "$work/early-stop-runner.py" "$project/tools/lib" "$work/early-suite.sh" "$work/early-logs" > "$work/output" 2>&1 &
early_runner=$!
early_runner_state="$(process_state "$early_runner")"
if wait "$early_runner"; then early_runner_code=0; else early_runner_code=$?; fi
expect 'RunnerGivenTermWhileItHandsASuiteToALane_Ends because a stop that lands as the suites are handed out must not hang the run' "$early_runner_state" ended
expect 'RunnerGivenTermWhileItHandsASuiteToALane_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped' "$early_runner_code" "$((signal_exit_base + $(kill -l TERM)))"
expect 'RunnerGivenTermWhileItHandsASuiteToALane_LeavesNoProcessBehind because a stopped run leaves no suite behind' "$(if [ -f "$work/early-suite" ]; then process_state "$(cat "$work/early-suite")"; else echo ended; fi)" ended
rm -r "$work/early-stop-runner.py" "$work/early-suite.sh" "$work/early-logs"; rm -f "$work/early-suite"
limit_seconds=3; default_limit_seconds=1800; grace_seconds=5; stop_bound_seconds=1
cat > "$suite/base-claim.sh" <<STUB
echo "  ok   Stub_CheckBeforeTheHang"
sleep $child_seconds &
echo \$! > "$work/child"
(trap 'sleep $cleanup_seconds; echo cleaned > "$work/cleanup"; exit 0' TERM; sleep $child_seconds) &
sleep $child_seconds
STUB
printf 'sleep %s\necho "  ok   Stub_WithinTheLimit"\n' "$lane_hold_seconds" > "$suite/sessions.sh"
suite_seconds() { awk -v name="$1" '$1 == "flow:" && $2 == name && ($3 == "pass" || $3 == "FAIL") { gsub(/[()s]/, "", $4); print int($4) }' "$work/output"; }
runner_lines_besides_start_and_end() { grep "^flow: $1 " "$work/output" | grep -vE "^flow: $1 (started\$|(pass|FAIL) \()"; }
starts_before_ends() { awk '/^flow: [^ ]+ started$/ { started[$2] = 1 } /^flow: [^ ]+ (pass|FAIL) \(/ { ended++; if (!started[$2]) unstarted++ } END { print (ended && !unstarted) ? "yes" : "no" }' "$work/output"; }
export FLOW_SUITE_LANES=1 FLOW_SUITE_TIME_LIMIT_SECONDS="$limit_seconds"
expect 'SuitePastItsTimeLimit_FailsTheRun because a hung suite proves nothing' "$(result)" fail
expect 'SuitePastItsTimeLimit_EndsItsChildCommands because a stopped suite leaves no check behind' "$(process_state "$(cat "$work/child")")" ended
expect 'SuiteChildCleaningUpAfterTerm_FinishesBeforeTheRunMovesOn because the grace time lasts until the whole group is gone' "$(cat "$work/cleanup" 2>/dev/null)" cleaned
expect 'SuitePastItsTimeLimit_PrintsItsOutputSoFarWithItsName because the owner must see how far it got' "$(grep -cFx '[base-claim]   ok   Stub_CheckBeforeTheHang' "$work/output")" 1
expect 'SuitePastItsTimeLimit_IsNamedWithTheLimit because the owner must see which suite hung and for how long' "$(runner_lines_besides_start_and_end base-claim | grep -cE "[^0-9]${limit_seconds}([^0-9]|\$)")" 1
expect 'SuiteAfterAHungSuite_StillRunsAndReports because one hung suite must not hold up the rest' "$(grep -cFx '[sessions]   ok   Stub_WithinTheLimit' "$work/output")" 1
expect 'SuiteWithinTheTimeLimit_Passes because only a suite past the limit is stopped' "$(grep -c '^flow: sessions pass (' "$work/output")" 1
expect 'SuitePastItsTimeLimit_IsReportedAsFailed because a stopped suite is never counted as a pass' "$(grep -c '^flow: base-claim FAIL (' "$work/output")" 1
expect 'SuiteWithinTheTimeLimit_IsNotNamedAsStopped because only a suite past the limit is stopped' "$(runner_lines_besides_start_and_end sessions | wc -l | tr -d ' ')" 0
expect 'EverySelectedSuite_PrintsExactlyOneStartLine because the reader must see each suite begin once' "$(grep -cE '^flow: [^ ]+ started$' "$work/output")" 2
expect 'SuitePastItsTimeLimit_IsNamedInTheSummary because a verify summary keeps only the last lines' "$(tail -1 "$work/output")" 'flow: failed in base-claim'
expect 'EverySelectedSuite_PrintsAStartLineBeforeItsEndLine because the reader must see which suites are running' "$(starts_before_ends)" yes
for bad in 0 abc -1 1.5 ''; do
  FLOW_SUITE_TIME_LIMIT_SECONDS="$bad"
  expect "TimeLimit${bad:-Empty}_Fails because only a whole number of seconds from 1 is a limit" "$(result)" fail
  expect "TimeLimit${bad:-Empty}_RunsNoSuite because a usage error comes before any suite starts" "$(suites_reported)" 0
  expect "TimeLimit${bad:-Empty}_NamesTheVariableAndTheValue because the owner must see what to fix" "$(tail -1 "$work/output" | grep -c -e "FLOW_SUITE_TIME_LIMIT_SECONDS.*'$bad'")" 1
done
unset FLOW_SUITE_LANES FLOW_SUITE_TIME_LIMIT_SECONDS
for bad in 0 abc -1 1.5 ''; do
  export FLOW_SUITE_STOP_GRACE_SECONDS="$bad"
  expect "StopGrace${bad:-Empty}_Fails because only a whole number of seconds from 1 is a grace time" "$(result)" fail
  expect "StopGrace${bad:-Empty}_NamesTheVariableAndTheValue because the owner must see what to fix" "$(tail -1 "$work/output" | grep -c -e "FLOW_SUITE_STOP_GRACE_SECONDS.*'$bad'")" 1
done
unset FLOW_SUITE_STOP_GRACE_SECONDS
rm "$work/child" "$work/cleanup"
git restore plugins/flow/tests/base-claim.sh plugins/flow/tests/sessions.sh
cat > "$work/deaf-suite.sh" <<STUB
trap '' TERM
echo "  ok   Stub_DeafToTerm"
sleep $child_seconds &
echo \$! > "$work/child"
: > "$work/deaf-suite-ready"
sleep $child_seconds
STUB
cat > "$work/stepping-runner.py" <<'PY'
import math
import subprocess
import sys
import time
from pathlib import Path
sys.path.append(sys.argv[1])
import flow_clock
import flow_process_groups
import flow_selection
import flow_suites

AWAIT_LIMIT_SECONDS = 30
AWAIT_POLL_SECONDS = 0.05


def running(pid: str, probe: Path) -> bool:
    return subprocess.run(["sh", str(probe), pid], timeout=AWAIT_LIMIT_SECONDS, check=False).returncode == 0


def wait_until_ended(awaited: Path, probe: Path) -> None:
    deadline = time.monotonic() + AWAIT_LIMIT_SECONDS
    while any(running(pid, probe) for pid in awaited.read_text().split()) and time.monotonic() < deadline:
        time.sleep(AWAIT_POLL_SECONDS)


class ClockThatStepsOnceTheSuiteIsReady:
    def __init__(self, ready: Path, awaits_from: float, awaited: Path, probe: Path) -> None:
        self.seconds = 0.0
        self.ready = ready
        self.awaits_from = awaits_from
        self.awaited = awaited
        self.probe = probe

    def now(self) -> flow_clock.Instant:
        return flow_clock.Instant(self.seconds)

    def sleep(self, duration: flow_clock.Duration) -> None:
        if self.seconds >= self.awaits_from:
            self.awaits_from = math.inf
            wait_until_ended(self.awaited, self.probe)
        if self.ready.exists():
            self.seconds += duration.seconds


name, script, ready, logs, awaits_from, awaited, process_table, probe = sys.argv[2:]
settings = flow_suites.settings_from({}, ClockThatStepsOnceTheSuiteIsReady(Path(ready), float(awaits_from), Path(awaited), Path(probe)), flow_process_groups.ProcessTable(Path(process_table)))
suites = {flow_selection.SuiteName(name): flow_selection.SuiteCommand(Path(script), None)}
sys.exit(flow_suites.report_run(flow_suites.run_selected(suites, flow_suites.SuiteLogs(Path(logs)), settings)))
PY
run_on_stepping_clock() { rm -rf "$work/stepping-logs"; mkdir "$work/stepping-logs"; python3 -I -B "$work/stepping-runner.py" "$project/tools/lib" "$1" "$2" "$3" "$work/stepping-logs" "$4" "$5" "$6" "$process_probe" > "$work/output" 2>&1; }
run_on_stepping_clock deaf "$work/deaf-suite.sh" "$work/deaf-suite-ready" inf /dev/null /proc &
stepping_runner=$!
expect 'SuitePastTheDefaultLimitOnTheClockItIsGiven_IsStoppedWithoutTheLimitPassingForReal because the runner times a suite by its injected clock' "$(process_state "$stepping_runner")" ended
wait "$stepping_runner" || true
expect 'SuiteDeafToTerm_HasItsChildKilled because a stopped suite leaves no check behind' "$(process_state "$(cat "$work/child")")" ended
expect 'SuiteDeafToTerm_IsKilledOnlyOnceTheGraceTimePasses because the group gets time to clean up before KILL' "$(if [ "$(suite_seconds deaf)" -gt "$default_limit_seconds" ]; then echo after-grace; else echo at-limit; fi)" after-grace
expect 'SuiteDeafToTerm_IsReportedAsFailed because a stopped suite is never counted as a pass' "$(tail -1 "$work/output")" 'flow: failed in deaf'
rm -r "$work/child" "$work/deaf-suite.sh" "$work/deaf-suite-ready" "$work/stepping-logs"
cat > "$work/parent-of-an-exited-child.py" <<'PY'
import os
import sys
import time
from pathlib import Path

exited_child_file, parent_file, ready_file, lifetime_seconds = sys.argv[1:]
reader, writer = os.pipe()
child = os.fork()
if child == 0:
    os._exit(0)
os.close(writer)
os.setpgid(0, 0)
os.read(reader, 1)
Path(exited_child_file).write_text(str(child))
Path(parent_file).write_text(str(os.getpid()))
Path(ready_file).touch()
time.sleep(int(lifetime_seconds))
PY
cat > "$work/exited-child-suite.sh" <<STUB
echo "  ok   Stub_LeavesAnExitedChild"
echo \$\$ > "$work/exited-child-suite-pids"
sleep $child_seconds &
echo \$! >> "$work/exited-child-suite-pids"
python3 -I "$work/parent-of-an-exited-child.py" "$work/exited-child" "$work/parent" "$work/exited-child-suite-ready" $child_seconds &
wait
STUB
run_on_stepping_clock exited "$work/exited-child-suite.sh" "$work/exited-child-suite-ready" "$default_limit_seconds" "$work/exited-child-suite-pids" /proc || true
expect 'SuiteWhoseGroupHoldsOnlyAnExitedChild_EndsBeforeTheGraceTimePasses because a child that has exited runs no check' "$(if [ "$(suite_seconds exited)" -lt "$((default_limit_seconds + grace_seconds))" ]; then echo before-grace; else echo after-grace; fi)" before-grace
expect 'SuiteWhoseGroupHoldsOnlyAnExitedChild_LeavesNoCheckRunning because a child that has exited but is not yet reaped runs nothing' "$(process_state "$(cat "$work/exited-child")")" ended
kill "$(cat "$work/parent")"
rm -r "$work/exited-child" "$work/parent" "$work/parent-of-an-exited-child.py" "$work/exited-child-suite.sh" "$work/exited-child-suite-ready" "$work/exited-child-suite-pids" "$work/stepping-logs"
cat > "$work/membership.py" <<'PY'
import sys
from pathlib import Path
sys.path.append(sys.argv[1])
import flow_process_groups

reader, group = sys.argv[2], flow_process_groups.ProcessGroupId(int(sys.argv[3]))
membership = flow_process_groups.table_membership(group, flow_process_groups.ProcessTable(Path(sys.argv[4]))) if reader == "table" else flow_process_groups.listing_membership(group)
print(membership.value)
PY
member_group=77; other_group=88; fake_table="$work/fake-proc"; name_not_utf8="$(printf 'cut\303')"
table_membership() { python3 -I -B "$work/membership.py" "$project/tools/lib" table "$member_group" "$1" 2>&1; }
fake_stat() { mkdir -p "$fake_table/$1"; printf '%s\n' "$2" > "$fake_table/$1/stat"; }
empty_table() { rm -rf "$fake_table"; mkdir "$fake_table"; }
empty_table; fake_stat 40 "40 (member) R 1 $member_group $member_group 0"; fake_stat 41 "41 ($name_not_utf8) S 1 $other_group $other_group 0"
expect 'ProcessTableHoldingAnUnrelatedNameThatIsNotUtf8_FindsTheMembers because any process on the machine may take any name' "$(table_membership "$fake_table")" 'members remain'
empty_table; fake_stat 41 "41 ($name_not_utf8) S 1 $member_group $member_group 0"
expect 'ProcessTableHoldingAMemberNameThatIsNotUtf8_FindsThatMember because only the fields after the name are read' "$(table_membership "$fake_table")" 'members remain'
empty_table; mkdir -p "$fake_table/42"; ln -s "$work/vanished" "$fake_table/42/stat"
expect 'ProcessTableWhoseProcessVanished_CountsItAsNoMember because a process may end between the listing and the read' "$(table_membership "$fake_table")" 'no member remains'
empty_table; fake_stat 43 "43 (locked) D 1 $member_group $member_group 0"; chmod 000 "$fake_table/43/stat"
if [ -r "$fake_table/43/stat" ]; then
  echo 'skip ProcessTableWithAnUnreadableStatus_CountsItAsNoMember: this user reads a file with no permissions'
else
  expect 'ProcessTableWithAnUnreadableStatus_CountsItAsNoMember because the runner may not read every process' "$(table_membership "$fake_table")" 'no member remains'
fi
chmod 600 "$fake_table/43/stat"
empty_table; fake_stat 44 "44 (short) S"
expect 'ProcessTableWithAShortStatus_CountsItAsNoMember because a line without its group names no group' "$(table_membership "$fake_table")" 'no member remains'
empty_table; fake_stat 45 "45 (odd) S 1 x$member_group x$member_group 0"; fake_stat 46 "46 no closing parenthesis S 1 $member_group $member_group"
expect 'ProcessTableWithAStatusThatDoesNotParse_CountsItAsNoMember because only a whole number names a group' "$(table_membership "$fake_table")" 'no member remains'
expect 'ProcessTableThatIsMissing_IsUnknown because a table that cannot be read says nothing of the group' "$(table_membership "$work/no-process-table")" unknown
empty_table; fake_stat 40 "40 (member) R 1 $member_group $member_group 0"; chmod 000 "$fake_table"
if ls "$fake_table" > /dev/null 2>&1; then
  echo 'skip ProcessTableThatCannotBeListed_IsUnknown: this user lists a folder with no permissions'
else
  expect 'ProcessTableThatCannotBeListed_IsUnknown because a table that cannot be read says nothing of the group' "$(table_membership "$fake_table")" unknown
fi
chmod 700 "$fake_table"
mkdir "$work/stub-ps"
cat > "$work/stub-ps/ps" <<STUB
#!/bin/sh
cat "$work/ps-output"
exit "\$(cat "$work/ps-code")"
STUB
chmod +x "$work/stub-ps/ps"
stub_listing() { printf '%s' "$1" > "$work/ps-output"; echo "$2" > "$work/ps-code"; }
listing_membership() { stub_listing "$1" "$2"; PATH="$work/stub-ps:$PATH" python3 -I -B "$work/membership.py" "$project/tools/lib" listing "$member_group" 2>&1; }
for code in 1 126; do
  expect "ProcessListingThatExits${code}_IsUnknown because a failed listing cannot show the group is gone" "$(listing_membership " $member_group R
" "$code")" unknown
done
expect 'ProcessListingThatPrintsNothing_FindsNoMember because an empty listing names no process' "$(listing_membership '' 0)" 'no member remains'
expect 'ProcessListingWithOnlyLinesThatDoNotParse_FindsNoMember because an odd line names no group' "$(listing_membership "garbage
$member_group
x$member_group R
$member_group R extra
" 0)" 'no member remains'
expect 'ProcessListingWithALineThatDoesNotParse_ReadsTheOtherLines because one odd line names no group' "$(listing_membership "garbage
 $member_group S
" 0)" 'members remain'
expect 'ProcessListingWithBytesThatAreNotUtf8_ReadsTheOtherLines because the listing is read as bytes' "$(listing_membership "$name_not_utf8 $member_group R
 $member_group S
" 0)" 'members remain'
cat > "$work/term-deaf-child-suite.sh" <<STUB
echo "  ok   Stub_LeavesAChildDeafToTerm"
sh -c 'trap "" TERM; echo \$\$ > "$work/child"; : > "$work/term-deaf-child-ready"; exec sleep $child_seconds' &
sleep $child_seconds
STUB
stub_listing '' 1
(PATH="$work/stub-ps:$PATH"; run_on_stepping_clock termdeaf "$work/term-deaf-child-suite.sh" "$work/term-deaf-child-ready" inf /dev/null "$work/no-process-table") &
stepping_runner=$!
expect 'SuiteWithAChildDeafToTermWhileTheListingFails_EndsTheRun because a group that cannot be seen must not hold up the run' "$(process_state "$stepping_runner")" ended
wait "$stepping_runner" || true
expect 'SuiteWithAChildDeafToTermWhileTheListingFails_HasTheChildKilled because a group that cannot be seen is killed once the grace time passes' "$(process_state "$(cat "$work/child")")" ended
expect 'SuiteWithAChildDeafToTermWhileTheListingFails_EndsAtTheGraceTime because a failed listing is no proof the group is gone' "$(if [ "$(suite_seconds termdeaf)" -ge "$((default_limit_seconds + grace_seconds))" ] && [ "$(suite_seconds termdeaf)" -lt "$((default_limit_seconds + grace_seconds + stop_bound_seconds))" ]; then echo at-grace; else echo "at $(suite_seconds termdeaf)s"; fi)" at-grace
rm -r "$fake_table" "$work/stub-ps" "$work/ps-output" "$work/ps-code" "$work/membership.py" "$work/child" "$work/term-deaf-child-suite.sh" "$work/term-deaf-child-ready" "$work/stepping-logs" "$work/stepping-runner.py"
mkdir "$work/holders"
for stub in "$suite"/*.sh; do
  cat > "$stub" <<STUB
: > "$work/holders/\$\$"
ls "$work/holders" | wc -l | tr -d ' ' >> "$work/holder-counts"
sleep $lane_hold_seconds
rm "$work/holders/\$\$"
STUB
done
most_suites_at_once() { sort -n "$work/holder-counts" | tail -1; rm "$work/holder-counts"; }
export FLOW_SUITE_LANES=1
expect 'OneLane_Passes because one lane is a valid count' "$(result)" pass
expect 'OneLane_RunsOneSuiteAtATime because a single lane never starts a second suite' "$(most_suites_at_once)" 1
FLOW_SUITE_LANES=3
expect 'ThreeLanes_Pass because the default count must work when named' "$(result)" pass
expect 'ThreeLanes_RunThreeSuitesAtOnce because each lane holds one suite' "$(most_suites_at_once)" 3
FLOW_SUITE_LANES=0
expect 'ZeroLanes_Fails because no suite could ever run' "$(result)" fail
expect 'ZeroLanes_NamesTheVariableAndTheValue because the owner must see what to fix' "$(tail -1 "$work/output" | grep -c "FLOW_SUITE_LANES.*'0'")" 1
for bad in abc -1 ''; do
  FLOW_SUITE_LANES="$bad"
  expect "LaneCount${bad:-Empty}_Fails because only a whole number from 1 is a lane count" "$(result)" fail
  expect "LaneCount${bad:-Empty}_NamesTheVariableAndTheValue because the owner must see what to fix" "$(tail -1 "$work/output" | grep -c -e "FLOW_SUITE_LANES.*'$bad'")" 1
done
unset FLOW_SUITE_LANES
rm -f "$work/holder-counts"
expect 'NoLaneVariable_Passes because the default must work' "$(result)" pass
expect 'NoLaneVariable_RunsThreeSuitesAtOnce because the default is three lanes' "$(most_suites_at_once)" 3
cp -p "$root/plugins/flow/tests/run.sh" "$suite/run.sh"
if "$project/tools/test.sh" flow > "$work/output" 2>&1; then whole_part=pass; else whole_part=fail; fi
expect 'FlowPart_Passes because CI runs the whole Flow part through it' "$whole_part" pass
expect 'FlowPart_RunsEverySuite because a full run leaves none out' "$(suites_reported)" 8
if sh "$suite/run.sh" inline > "$work/output" 2>&1; then dispatcher_code=0; else dispatcher_code=$?; fi
expect 'FlowDispatcherGivenAnArgument_IsAUsageError because run.sh only hands the whole run to the runner' "$dispatcher_code" 2
