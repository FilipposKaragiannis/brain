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
child_seconds=120; cleanup_seconds=1; ticks_per_second=10
signal_exit_base=128; terminate_signal_number=15; interrupt_signal_number=2; hangup_signal_number=1
stop_grace_seconds=2; stop_margin_seconds=3
shared_grace_seconds=4; shared_grace_margin_seconds=2; later_signal_seconds=3

all_exist() { for all_exist_path in "$@"; do [ -f "$all_exist_path" ] || return 1; done; }
await_all() {
  await_all_ticks=0
  until all_exist "$@" || [ "$await_all_ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; await_all_ticks=$((await_all_ticks + 1)); done
}
state_within() {
  state_within_ticks=0
  while process_running "$1" && [ "$state_within_ticks" -lt "$(($2 * ticks_per_second))" ]; do sleep "$poll_seconds"; state_within_ticks=$((state_within_ticks + 1)); done
  if process_running "$1"; then kill -KILL "$1"; echo running; else echo ended; fi
}
any_running() { ps -o stat= -p "$1" 2> /dev/null | grep -qv '^ *Z'; }
deaf_suites_left() {
  deaf_suites_left_ids="$(paste -sd, "$work/deaf-ids")"
  deaf_suites_left_ticks=0
  while any_running "$deaf_suites_left_ids" && [ "$deaf_suites_left_ticks" -lt "$wait_ticks" ]; do sleep "$poll_seconds"; deaf_suites_left_ticks=$((deaf_suites_left_ticks + 1)); done
  if any_running "$deaf_suites_left_ids"; then xargs kill -KILL < "$work/deaf-ids" 2> /dev/null || true; echo some; else echo none; fi
}
await_output() {
  await_output_ticks=0
  until [ -s "$work/output" ] || [ "$await_output_ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; await_output_ticks=$((await_output_ticks + 1)); done
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
sh -c 'trap "" TERM; echo \$\$ > "$work/deaf-descendant"; : > "$work/deaf-descendant-ready"; exec sleep $child_seconds' &
sleep $child_seconds
STUB
cat > "$suite/verify-scope.sh" <<STUB
(trap 'sleep $cleanup_seconds; echo cleaned > "$work/cleanup"; exit 0' TERM; : > "$work/cleaning-suite-ready"; sleep $child_seconds) &
sleep $child_seconds
STUB
FLOW_SUITE_STOP_GRACE_SECONDS="$stop_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/deaf-suite-ready" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready"
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code=0; else runner_code=$?; fi
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_EndsWithinTheGraceTime because a suite deaf to TERM must not hold up cancellation' "$(ended_within "$runner_state" "$runner_seconds" "$((stop_grace_seconds + stop_margin_seconds))")" in-time
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_EndsThatSuite because a stopped run leaves no suite behind' "$(process_state "$(cat "$work/deaf-suite")")" ended
expect 'RunnerGivenTermWhileADescendantIgnoresTerm_EndsThatDescendant because a stopped run leaves no check behind' "$(process_state "$(cat "$work/deaf-descendant")")" ended
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped' "$runner_code" "$((signal_exit_base + terminate_signal_number))"
expect 'RunnerGivenTermWhileASuiteIgnoresTerm_NamesThatSuiteAsStopped because the owner must see where the run stood' "$(grep -cx 'flow: sessions stopped' "$work/output")" 1
expect 'RunnerGivenTermWhileASuiteCleansUp_LetsItFinishItsCleanup because a suite that honours TERM is never killed before its cleanup ends' "$(cat "$work/cleanup" 2> /dev/null)" cleaned
rm "$work/deaf-suite" "$work/deaf-suite-ready" "$work/deaf-descendant" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready" "$work/cleanup"

mkdir "$work/stub-ps"
printf '%s\n' '#!/bin/sh' "exec sleep $child_seconds" > "$work/stub-ps/ps"
chmod +x "$work/stub-ps/ps"
PATH="$work/stub-ps:$PATH" FLOW_SUITE_STOP_GRACE_SECONDS="$stop_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/deaf-suite-ready" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready"
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
wait "$runner" || true
expect 'RunnerGivenTermWhileTheProcessListingHangs_EndsBeforeVerifyKillsIt because a listing that hangs must not outlast the grace time' "$(ended_within "$runner_state" "$runner_seconds" "$((verify_stop_grace_seconds - 1))")" in-time
expect 'RunnerGivenTermWhileTheProcessListingHangs_EndsTheDescendantDeafToTerm because a group that cannot be listed is killed when the grace time ends' "$(process_state "$(cat "$work/deaf-descendant")")" ended
rm -r "$work/stub-ps" "$work/deaf-suite" "$work/deaf-suite-ready" "$work/deaf-descendant" "$work/deaf-descendant-ready" "$work/cleaning-suite-ready"; rm -f "$work/cleanup"

for deaf_suite in sessions base-claim verify-scope; do
  printf '%s\n' "trap '' TERM" "echo \$\$ >> \"$work/deaf-ids\"" ": > \"$work/$deaf_suite-ready\"" "sleep $child_seconds" > "$suite/$deaf_suite.sh"
done
FLOW_SUITE_STOP_GRACE_SECONDS="$shared_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
kill -INT "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code=0; else runner_code=$?; fi
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsWithinOneGraceTime because all running suites share one grace time and not one each' "$(ended_within "$runner_state" "$runner_seconds" "$((shared_grace_seconds + shared_grace_margin_seconds))")" in-time
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_suites_left)" none
expect 'RunnerGivenIntWhileSeveralSuitesIgnoreTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see which signal stopped the run' "$runner_code" "$((signal_exit_base + interrupt_signal_number))"
rm "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"

FLOW_SUITE_STOP_GRACE_SECONDS="$shared_grace_seconds" python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
kill -HUP "$runner"; stop_sent_at="$(date +%s)"
sleep "$later_signal_seconds"
kill -TERM "$runner" 2> /dev/null || true
kill -INT "$runner" 2> /dev/null || true
runner_state="$(state_within "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
if wait "$runner"; then runner_code=0; else runner_code=$?; fi
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsWithinOneGraceTime because a later signal must not restart or lengthen the wait' "$(ended_within "$runner_state" "$runner_seconds" "$((shared_grace_seconds + shared_grace_margin_seconds))")" in-time
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_ExitsWith128PlusTheFirstSignalNumber because a later signal must not stop the run a second time' "$runner_code" "$((signal_exit_base + hangup_signal_number))"
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_PrintsNoTraceback because a signal must not raise from inside the runner' "$(grep -c Traceback "$work/output")" 0
expect 'RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_suites_left)" none
rm "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"

python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_all "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"
kill -TERM "$runner"; stop_sent_at="$(date +%s)"
runner_state="$(state_within "$runner" "$verify_stop_grace_seconds")"; runner_seconds="$(($(date +%s) - stop_sent_at))"
wait "$runner" || true
expect 'RunnerGivenTermWithTheDefaultGrace_EndsBeforeVerifyKillsIt because verify kills only the runner and each suite runs in a session of its own' "$(ended_within "$runner_state" "$runner_seconds" "$((verify_stop_grace_seconds - 1))")" in-time
expect 'RunnerGivenTermWithTheDefaultGrace_EndsEverySuite because a stopped run leaves no suite behind' "$(deaf_suites_left)" none
rm "$work/deaf-ids" "$work/sessions-ready" "$work/base-claim-ready" "$work/verify-scope-ready"

rm "$work/output"
python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
await_output
kill -TERM "$runner"
runner_state="$(state_within "$runner" "$verify_stop_grace_seconds")"
if wait "$runner"; then runner_code=0; else runner_code=$?; fi
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

SUITE_SECONDS = "120"
WAIT_LIMIT_SECONDS = 2
TIME_LIMIT = flow_clock.Duration(1800)
AFTER_THE_CLOSE = "after-the-close"


def fate_of(suite: subprocess.Popen) -> str:
    try:
        suite.wait(timeout=WAIT_LIMIT_SECONDS)
    except subprocess.TimeoutExpired:
        suite.kill()
        return "running"
    return "killed"


running = flow_running_suites.RunningSuites()
if sys.argv[2] == AFTER_THE_CLOSE:
    running.close()
with subprocess.Popen(["sleep", SUITE_SECONDS], start_new_session=True) as started:
    with running.track(flow_process_groups.LedGroup(started, flow_process_groups.ProcessGroupId(started.pid)), TIME_LIMIT) as admitted:
        print(fate_of(started), f"{admitted.time_limit.seconds:g}")
PY
tracked_after_the_close="$(python3 -I -B "$work/tracked-suite.py" "$project/tools/lib" after-the-close 2>&1)"
tracked_before_the_close="$(python3 -I -B "$work/tracked-suite.py" "$project/tools/lib" before-the-close 2>&1)"
expect 'SuiteALaneStartsAfterTheStop_IsKilledAtOnce because no suite may run on unseen once the stop has taken its list' "${tracked_after_the_close% *}" killed
expect 'SuiteALaneStartsAfterTheStop_GetsNoTime because its lane must not wait on a suite the stop never saw' "${tracked_after_the_close#* }" 0
expect 'SuiteALaneStartsBeforeTheStop_KeepsRunning because only a stop or its time limit ends a suite early' "${tracked_before_the_close% *}" running
expect 'SuiteALaneStartsBeforeTheStop_KeepsItsTimeLimit because an admitted suite runs under the limit it was given' "${tracked_before_the_close#* }" 1800
