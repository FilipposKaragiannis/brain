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
printf '%s\n' 'echo "tracker mode ${FLOW_TRACKER_STATE:-unset}"' > "$suite/sessions.sh"
FLOW_TRACKER_STATE=none python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 || true
expect 'RunGivenATrackerMode_HandsItToItsSuites because the none pass proves nothing if its suites run under labels' "$(grep -cFx '[sessions] tracker mode none' "$work/output")" 1
git restore plugins/flow/tests/sessions.sh
limit_seconds=3; cleanup_seconds=1; default_limit_seconds=1800; grace_seconds=5; stop_bound_seconds=1
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
import flow_clock
import flow_process_groups

LISTING_LIMIT_SECONDS = 10
reader, group = sys.argv[2], flow_process_groups.ProcessGroupId(int(sys.argv[3]))
membership = flow_process_groups.table_membership(group, flow_process_groups.ProcessTable(Path(sys.argv[4]))) if reader == "table" else flow_process_groups.listing_membership(group, flow_clock.Duration(LISTING_LIMIT_SECONDS))
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
barrier_ticks=30; first_tick=0; one_tick=1
for stub in "$suite"/*.sh; do
  cat > "$stub" <<STUB
: > "$work/holders/\$\$"
waited=$first_tick
until [ "\$(ls "$work/holders" | wc -l | tr -d ' ')" -ge "\$(cat "$work/lanes-expected")" ] || [ "\$waited" -ge $barrier_ticks ]; do sleep $poll_seconds; waited=\$((waited + $one_tick)); done
ls "$work/holders" | wc -l | tr -d ' ' >> "$work/holder-counts"
sleep $lane_hold_seconds
rm "$work/holders/\$\$"
STUB
done
most_suites_at_once() { sort -n "$work/holder-counts" | tail -1; rm "$work/holder-counts"; }
export FLOW_SUITE_LANES=1
echo "$FLOW_SUITE_LANES" > "$work/lanes-expected"
expect 'OneLane_Passes because one lane is a valid count' "$(result)" pass
expect 'OneLane_RunsOneSuiteAtATime because a single lane never starts a second suite' "$(most_suites_at_once)" 1
FLOW_SUITE_LANES=3
echo "$FLOW_SUITE_LANES" > "$work/lanes-expected"
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
default_lanes=3; echo "$default_lanes" > "$work/lanes-expected"
rm -f "$work/holder-counts"
expect 'NoLaneVariable_Passes because the default must work' "$(result)" pass
expect 'NoLaneVariable_RunsThreeSuitesAtOnce because the default is three lanes' "$(most_suites_at_once)" 3
cp -p "$root/plugins/flow/tests/run.sh" "$suite/run.sh"
if "$project/tools/test.sh" flow > "$work/output" 2>&1; then whole_part=pass; else whole_part=fail; fi
expect 'FlowPart_Passes because CI runs the whole Flow part through it' "$whole_part" pass
expect 'FlowPart_RunsEverySuite because a full run leaves none out' "$(suites_reported)" 8
if sh "$suite/run.sh" inline > "$work/output" 2>&1; then dispatcher_code=0; else dispatcher_code=$?; fi
expect 'FlowDispatcherGivenAnArgument_IsAUsageError because run.sh only hands the whole run to the runner' "$dispatcher_code" 2
