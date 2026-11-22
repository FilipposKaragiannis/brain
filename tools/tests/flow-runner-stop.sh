#!/bin/sh
# Tests that a TERM, INT or HUP stops Brain's Flow suite runner within its grace time and leaves
# no suite behind. Takes no argument.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tools="$root/tools"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

# shellcheck source=tools/tests/_flow_project_fixture.sh
. "$here/_flow_project_fixture.sh"
# shellcheck source=plugins/flow/lib/verify.sh
verify_stop_grace_seconds="$(FLOW_PLUGIN="$root/plugins/flow"; . "$root/plugins/flow/lib/verify.sh"; echo "$VERIFY_STOP_GRACE")"
child_seconds=120; cleanup_seconds=1; ticks_per_second=10; first_tick=0; one_tick=1
success_code=0; failure_code=1; once=1; never=0; verify_margin_seconds=1; time_limit_seconds=1800; no_seconds=0
signal_exit_base=128; terminate_signal_number=15; interrupt_signal_number=2; hangup_signal_number=1
stop_grace_seconds=2; stop_margin_seconds=3
shared_grace_seconds=4; shared_grace_margin_seconds=2; later_signal_seconds=3

all_exist() { for all_exist_path in "$@"; do [ -f "$all_exist_path" ] || return "$failure_code"; done; }
await_all() {
  await_all_ticks="$first_tick"
  until all_exist "$@" || [ "$await_all_ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; await_all_ticks=$((await_all_ticks + one_tick)); done
}
state_within_killing_a_survivor() {
  state_within_killing_a_survivor_ticks="$first_tick"
  while process_running "$1" && [ "$state_within_killing_a_survivor_ticks" -lt "$(($2 * ticks_per_second))" ]; do sleep "$poll_seconds"; state_within_killing_a_survivor_ticks=$((state_within_killing_a_survivor_ticks + one_tick)); done
  if process_running "$1"; then kill -KILL "$1"; echo running; else echo ended; fi
}
any_running() { ps -o stat= -p "$1" 2> /dev/null | grep -qv '^ *Z'; }
deaf_suites_left_killing_them() {
  deaf_suites_left_killing_them_ids="$(paste -sd, "$work/deaf-ids")"
  deaf_suites_left_killing_them_ticks="$first_tick"
  while any_running "$deaf_suites_left_killing_them_ids" && [ "$deaf_suites_left_killing_them_ticks" -lt "$wait_ticks" ]; do sleep "$poll_seconds"; deaf_suites_left_killing_them_ticks=$((deaf_suites_left_killing_them_ticks + one_tick)); done
  if any_running "$deaf_suites_left_killing_them_ids"; then xargs kill -KILL < "$work/deaf-ids" 2> /dev/null || true; echo some; else echo none; fi
}
await_output() {
  await_output_ticks="$first_tick"
  until [ -s "$work/output" ] || [ "$await_output_ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; await_output_ticks=$((await_output_ticks + one_tick)); done
}
ended_within() { if [ "$1" = ended ] && [ "$2" -le "$3" ]; then echo in-time; else echo "$1 after ${2}s"; fi; }

cat > "$suite/sessions.sh" <<STUB
trap '' TERM
echo "  ok   Stub_DeafToTerm"
echo \$\$ > "$work/deaf-suite"
: > "$work/deaf-suite-ready"
sleep $child_seconds
STUB
cat > "$suite/base-claim.sh" <<STUB
sh -c 'trap "" TERM; echo \$\$ > "\$1"; : > "\$2"; exec sleep "\$3"' deaf-descendant "$work/deaf-descendant" "$work/deaf-descendant-ready" "$child_seconds" &
sleep $child_seconds
STUB
cat > "$suite/verify-scope.sh" <<STUB
(trap 'sleep $cleanup_seconds; echo cleaned > "$work/cleanup"; exit $success_code' TERM; : > "$work/cleaning-suite-ready"; sleep $child_seconds) &
sleep $child_seconds
STUB
FLOW_SUITE_STOP_GRACE_SECONDS="$stop_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/deaf-suite-ready" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready"
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within_killing_a_survivor "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code="$success_code"; else runner_code=$?; fi
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_EndsWithinTheGraceTime because a suite deaf to TERM must not hold up cancellation' "$(ended_within "$runner_state" "$runner_seconds" "$((stop_grace_seconds + stop_margin_seconds))")" in-time
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_EndsThatSuite because a stopped run leaves no suite behind' "$(process_state "$(cat "$work/deaf-suite")")" ended
expect 'RunnerGivenTermWhileADescendantIgnoresTerm_EndsThatDescendant because a stopped run leaves no check behind' "$(process_state "$(cat "$work/deaf-descendant")")" ended
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped' "$runner_code" "$((signal_exit_base + terminate_signal_number))"
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_NamesThatSuiteAsStopped because the owner must see where the run stood' "$(grep -cx 'flow: sessions stopped' "$work/output")" "$once"
expect 'RunnerGivenTermWhileASuiteCleansUp_LetsItFinishItsCleanup because a suite that honours TERM is never killed before its cleanup ends' "$(cat "$work/cleanup" 2> /dev/null)" cleaned
rm "$work/deaf-suite" "$work/deaf-suite-ready" "$work/deaf-descendant" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready" "$work/cleanup"

cat > "$work/listing-runner.py" <<'PY'
import sys
from pathlib import Path

sys.path.append(sys.argv[1])
import flow_clock
import flow_process_groups
import flow_selection
import flow_suites

suite_script, logs, missing_process_table, grace = sys.argv[2:]
settings = flow_suites.settings_from({"FLOW_SUITE_STOP_GRACE_SECONDS": grace}, flow_clock.SystemClock(), flow_process_groups.ProcessTable(Path(missing_process_table)))
suites = {flow_selection.SuiteName("descendant"): flow_selection.SuiteCommand(Path(suite_script), None)}
sys.exit(flow_suites.report_run(flow_suites.run_selected(suites, flow_suites.SuiteLogs(Path(logs)), settings)))
PY
mkdir "$work/stub-ps" "$work/listing-logs"
printf '%s\n' '#!/bin/sh' "exec sleep $child_seconds" > "$work/stub-ps/ps"
chmod +x "$work/stub-ps/ps"
PATH="$work/stub-ps:$PATH" python3 -I -B "$work/listing-runner.py" "$project/tools/lib" "$suite/base-claim.sh" "$work/listing-logs" "$work/no-process-table" "$stop_grace_seconds" > "$work/output" 2>&1 &
runner=$!
await_all "$work/deaf-descendant-ready"
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within_killing_a_survivor "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
wait "$runner" || true
expect 'RunnerGivenTermWhileTheProcessListingHangs_EndsBeforeVerifyKillsIt because a listing that hangs must not outlast the grace time' "$(ended_within "$runner_state" "$runner_seconds" "$((verify_stop_grace_seconds - verify_margin_seconds))")" in-time
expect 'RunnerGivenTermWhileTheProcessListingHangs_EndsTheDescendantDeafToTerm because a group that cannot be listed is killed when the grace time ends' "$(process_state "$(cat "$work/deaf-descendant")")" ended
rm -r "$work/stub-ps" "$work/listing-logs" "$work/listing-runner.py" "$work/deaf-descendant" "$work/deaf-descendant-ready"

for deaf_suite in sessions base-claim verify-scope; do
  printf '%s\n' "trap '' TERM" "echo \$\$ >> \"$work/deaf-ids\"" ": > \"$work/$deaf_suite-ready\"" "sleep $child_seconds" > "$suite/$deaf_suite.sh"
done
FLOW_SUITE_STOP_GRACE_SECONDS="$shared_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
kill -INT "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within_killing_a_survivor "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code="$success_code"; else runner_code=$?; fi
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsWithinOneGraceTime because all running suites share one grace time and not one each' "$(ended_within "$runner_state" "$runner_seconds" "$((shared_grace_seconds + shared_grace_margin_seconds))")" in-time
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_suites_left_killing_them)" none
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see which signal stopped the run' "$runner_code" "$((signal_exit_base + interrupt_signal_number))"
rm "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"

FLOW_SUITE_STOP_GRACE_SECONDS="$shared_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
kill -HUP "$runner"; stop_sent_at="$(date +%s)"
sleep "$later_signal_seconds"
kill -TERM "$runner" 2> /dev/null || true
kill -INT "$runner" 2> /dev/null || true
runner_state="$(state_within_killing_a_survivor "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code="$success_code"; else runner_code=$?; fi
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsWithinOneGraceTime because a later signal must not restart or lengthen the wait' "$(ended_within "$runner_state" "$runner_seconds" "$((shared_grace_seconds + shared_grace_margin_seconds))")" in-time
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_ExitsWith128PlusTheFirstSignalNumber because a later signal must not stop the run a second time' "$runner_code" "$((signal_exit_base + hangup_signal_number))"
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_PrintsNoTraceback because a signal must not raise from inside the runner' "$(grep -c Traceback "$work/output")" "$never"
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_suites_left_killing_them)" none
rm "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"

python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within_killing_a_survivor "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
wait "$runner" || true
expect 'RunnerGivenTermWithTheDefaultGrace_EndsBeforeVerifyKillsIt because verify kills only the runner and each suite runs in a session of its own' "$(ended_within "$runner_state" "$runner_seconds" "$((verify_stop_grace_seconds - verify_margin_seconds))")" in-time
expect 'RunnerGivenTermWithTheDefaultGrace_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_suites_left_killing_them)" none
rm "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"

rm "$work/output"
python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_output
kill -TERM "$runner"
runner_state="$(state_within_killing_a_survivor "$runner" "$verify_stop_grace_seconds")"
if wait "$runner"; then runner_code="$success_code"; else runner_code=$?; fi
expect 'RunnerGivenTermAsItStarts_Ends because a stop that lands while the suites are handed out must not hang the run' "$runner_state" ended
expect 'RunnerGivenTermAsItStarts_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped' "$runner_code" "$((signal_exit_base + terminate_signal_number))"
rm -f "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
git restore plugins/flow/tests/sessions.sh plugins/flow/tests/base-claim.sh plugins/flow/tests/verify-scope.sh

cat > "$work/tracked-suite.py" <<'PY'
import subprocess
import sys

sys.path.append(sys.argv[1])
import flow_clock
import flow_process_groups
import flow_running_suites

suite_seconds, time_limit_seconds, when_tracked = sys.argv[2:]
WAIT_LIMIT_SECONDS = 2
AFTER_THE_CLOSE = "after-the-close"


def fate_killing_a_survivor(suite: subprocess.Popen) -> str:
    try:
        suite.wait(timeout=WAIT_LIMIT_SECONDS)
    except subprocess.TimeoutExpired:
        suite.kill()
        return "running"
    return "killed"


running = flow_running_suites.RunningSuites()
if when_tracked == AFTER_THE_CLOSE:
    running.close()
with subprocess.Popen(["sleep", suite_seconds], start_new_session=True) as started:
    with running.track_or_kill_after_the_close(flow_process_groups.LedGroup(started, flow_process_groups.ProcessGroupId(started.pid)), flow_clock.Duration(float(time_limit_seconds))) as admitted:
        print(fate_killing_a_survivor(started), f"{admitted.time_limit.seconds:g}")
PY
tracked_after_the_close="$(python3 -I -B "$work/tracked-suite.py" "$project/tools/lib" "$child_seconds" "$time_limit_seconds" after-the-close 2>&1)"
tracked_before_the_close="$(python3 -I -B "$work/tracked-suite.py" "$project/tools/lib" "$child_seconds" "$time_limit_seconds" before-the-close 2>&1)"
expect 'SuiteALaneStartsAfterTheStop_IsKilledAtOnce because no suite may run on unseen once the stop has taken its list' "${tracked_after_the_close% *}" killed
expect 'SuiteALaneStartsAfterTheStop_GetsNoTime because its lane must not wait on a suite the stop never saw' "${tracked_after_the_close#* }" "$no_seconds"
expect 'SuiteALaneStartsBeforeTheStop_KeepsRunning because only a stop or its time limit ends a suite early' "${tracked_before_the_close% *}" running
expect 'SuiteALaneStartsBeforeTheStop_KeepsItsTimeLimit because an admitted suite runs under the limit it was given' "${tracked_before_the_close#* }" "$time_limit_seconds"
