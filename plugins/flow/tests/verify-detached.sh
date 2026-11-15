#!/bin/sh
# verify-detached.sh: a verify run started with verify.sh <item> --start runs detached and is
# waited on with --wait, on the local adapter in throwaway repos. --start returns while the checks
# run and clears the earlier report; a second --start while one runs starts nothing; --wait exits
# 0 on pass, 1 on fail (a gate that failed, a run past verify.limit, a run killed with no report),
# 3 while it runs and 2 with no run, also where ps cannot run; verify.limit stops the gate's whole
# process group; steward stop and release end the run (stop with no run record, release before its
# dirty check refuses), never another item's, and release gives up on a run that outlives its
# wait; health does not take an item whose verify runs for dead, and counts a run only in the
# item's own worktree. A verify.run field that holds a command runs nothing, and --start never
# writes through a link.
# Each gate waits for a file the test creates, so the test decides when a check ends.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
# On exit every held gate is let go, so no detached run outlives the test.
trap 'for gate_name in started refused unstarted killed stopped released health stopless dirty planted stubborn tampered; do touch "$work/release-$gate_name"; done; [ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
. "$here/_verify_fixture.sh"

echo "verify --start returns while the checks run, and --wait follows the run"
new_item started "$(held_gate started)"
printf '{"status":"pass","checks":[]}\n' > "$reports/verify.json"; printf 'earlier\n' > "$reports/verify.md"
# --start runs in the background: one that waited for its gate would never end, as the gate is
# held, so the check fails on the time instead of hanging the suite.
(verify --start >/dev/null 2>&1; echo "$?" > "$work/start.code") &
check "StartWithAGateStillRunning_ReturnsAtOnce: --start detaches the checks instead of waiting for them" \
  'until_true 30 "[ -s $work/start.code ]"'
check "StartWithAGateStillRunning_ExitsZero: a started run is no failure" '[ "$(cat "$work/start.code")" = 0 ]'
check "StartAfterAnEarlierRun_RemovesTheEarlierVerifyJson: no report of an earlier run may read as this one's" \
  '[ ! -f "$reports/verify.json" ]'
check "StartAfterAnEarlierRun_RemovesTheEarlierVerifyMd: the PR body never embeds an earlier run's twin" \
  '[ ! -f "$reports/verify.md" ]'
check "StartedRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/started.count ]"'
verify --wait 1 >/dev/null 2>&1; running_code=$?
check "WaitWhileTheGateRuns_ExitsThree: 3 tells the verifier to call --wait again" '[ "$running_code" -eq 3 ]'
verify --start >/dev/null 2>&1
touch "$work/release-started"
wait_until_ended; ended_code=$?
check "SecondStartWhileARunGoes_StartsNothing: the checks run once, in the run already going" \
  '[ "$(wc -l < "$work/started.count" | tr -d " ")" = 1 ]'
check "WaitAfterAPassingRun_ExitsZero: 0 is a pass" '[ "$ended_code" -eq 0 ]'
check "WaitAfterAPassingRun_ReportSaysPass: the report the run wrote is the step result" '[ "$(report_status)" = pass ]'

echo "verify --wait after a failing gate"
new_item failing "$(held_gate failing)"
touch "$work/fail-failing" "$work/release-failing"
verify --start >/dev/null 2>&1
wait_until_ended; ended_code=$?
check "WaitAfterAFailingGate_ExitsOne: 1 is a fail" '[ "$ended_code" -eq 1 ]'
check "WaitAfterAFailingGate_ReportSaysFail: the failed gate fails the run" '[ "$(report_status)" = fail ]'

echo "verify where ps cannot run, as a sandbox refuses the setuid /bin/ps"
new_item refused "$(held_gate refused)"
mkdir -p "$work/refused-ps" && printf '#!/bin/sh\necho "ps: Operation not permitted" >&2\nexit 126\n' > "$work/refused-ps/ps" && chmod +x "$work/refused-ps/ps"
path_with_ps="$PATH"; PATH="$work/refused-ps:$PATH"
verify --start >/dev/null 2>&1
check "StartWhereNoPsRuns_GateStarts: the detached run reaches its checks without ps" \
  'until_true 20 "[ -s $work/refused.count ]"'
verify --wait 1 >/dev/null 2>&1; refused_running_code=$?
check "WaitWhileTheGateRunsWhereNoPsRuns_ExitsThree: a run still going never reads as one that died" '[ "$refused_running_code" -eq 3 ]'
touch "$work/release-refused"
wait_until_ended; ended_code=$?
PATH="$path_with_ps"
check "WaitAfterAPassingRunWhereNoPsRuns_ExitsZero: the run's own report is the step result" '[ "$ended_code" -eq 0 ]'

echo "verify --wait with no run started"
new_item unstarted "$(held_gate unstarted)"
verify --wait 1 >/dev/null 2>&1; unstarted_code=$?
check "WaitWithNoRunStarted_ExitsTwo: there is nothing to wait for" '[ "$unstarted_code" -eq 2 ]'

echo "a run killed with no report"
new_item killed "$(held_gate killed)"
verify --start >/dev/null 2>&1
check "KilledRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/killed.count ]"'
killed_pid="$(run_pid)"
check "KilledRun_RecordNamesALiveProcess: the record must name the run, or the kill below proves nothing" \
  'process_running "$killed_pid"'
kill -9 -"$killed_pid" 2>/dev/null || kill -9 "$killed_pid"
check "KilledRun_HasEnded: the kill must take, or the wait below reads a run still going" \
  'until_true 20 "! process_running $killed_pid"'
wait_until_ended; ended_code=$?
check "WaitAfterTheRunWasKilled_ExitsOne: a run that died with no report is a fail" '[ "$ended_code" -eq 1 ]'
check "WaitAfterTheRunWasKilled_ReportSaysFail: the verifier still has a report to read" '[ "$(report_status)" = fail ]'

echo "verify.limit stops a run that takes longer"
limit_yaml="verify:
  limit: 5s
"
# The gate never ends on its own: its child waits for the test's folder to go.
new_item limited "  slow: 'sh -c \"sh -c \\\"while [ -d $work ]; do sleep 1; done\\\" & echo \\\$! > $work/slow-child.pid; wait\"'"
limit_yaml=""
verify --start >/dev/null 2>&1
check "LimitedRun_GateChildStarts: the gate's child must have started, or its end below proves nothing" \
  'until_true 20 "[ -s $work/slow-child.pid ]"'
slow_child="$(cat "$work/slow-child.pid")"
check "LimitedRun_GateChildRunsBeforeTheLimit: the child must run, or its end below proves nothing" \
  'process_running "$slow_child"'
wait_until_ended; ended_code=$?
check "RunPastTheLimit_WaitExitsOne: a run stopped at verify.limit is a fail" '[ "$ended_code" -eq 1 ]'
check "RunPastTheLimit_ReportNamesTheCheckThatRan: the owner learns which gate is slow" \
  '[ "$(failed_checks)" = "gate slow" ]'
check "RunPastTheLimit_GateChildIsStopped: the whole process group stops, not only the run" \
  'until_true 20 "! process_running $slow_child"'

echo "steward stop and release end the detached run"
new_item stopped "$(held_gate stopped)"
record_a_dead_agent
verify --start >/dev/null 2>&1
check "StoppedRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/stopped.count ]"'
stopped_pid="$(run_pid)"
check "StoppedRun_RecordNamesALiveProcess: the record must name the run, or its end below proves nothing" \
  'process_running "$stopped_pid"'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1
check "StewardStopOnAnItemWithADetachedVerify_EndsTheVerifyRun: a stopped item runs nothing" \
  'until_true 30 "! process_running $stopped_pid"'

new_item released "$(held_gate released)"
verify --start >/dev/null 2>&1
check "ReleasedRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/released.count ]"'
released_pid="$(run_pid)"
check "ReleasedRun_RecordNamesALiveProcess: the record must name the run, or its end below proves nothing" \
  'process_running "$released_pid"'
rm -f ".flow/runs/$(slug "$item").json"
"$plugin/scripts/steward.sh" release "$item" --force >/dev/null 2>&1
check "StewardReleaseOfAnItemWithADetachedVerify_EndsTheVerifyRun: a released worktree is not checked on" \
  'until_true 30 "! process_running $released_pid"'

echo "health counts a detached verify run as the item's live run"
new_item health "$(held_gate health)"
printf 'jobs:\n  health:\n    grace: 1s\n' >> .flow/config.yaml
record_a_dead_agent
verify --start >/dev/null 2>&1
check "HealthRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/health.count ]"'
env -u FLOW_HEALTH_PROCS "$plugin/scripts/steward.sh" health --dry-run > "$work/health-live.out" 2>&1
check "HealthWhileTheDetachedVerifyRuns_DoesNotTakeTheRunForDead: the verify run is the item's live run" \
  '! grep -q "$item.*dead run" "$work/health-live.out"'
touch "$work/release-health"
wait_until_ended
# The run's processes may still be in the list a moment after --wait saw the run end, so health is
# asked again until it takes the run for dead.
check "HealthAfterTheDetachedVerifyEnded_TakesTheRunForDead: the record is the same, so only the verify run kept it alive" \
  'until_true 30 "env -u FLOW_HEALTH_PROCS \"$plugin/scripts/steward.sh\" health --dry-run 2>&1 | grep -q \"$item.*dead run\""'

echo "steward stop with no run record still ends the detached run"
new_item stopless "$(held_gate stopless)"
rm -f ".flow/runs/$(slug "$item").json"
verify --start >/dev/null 2>&1
check "StoplessRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/stopless.count ]"'
stopless_pid="$(run_pid)"
check "StoplessRun_RecordNamesALiveProcess: the record must name the run, or its end below proves nothing" \
  'process_running "$stopless_pid"'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1
check "StewardStopWithNoRunRecord_EndsTheVerifyRun: a verify started by hand is still the item's run to stop" \
  'until_true 30 "! process_running $stopless_pid"'
check "StewardStopWithNoRunRecord_RunLeavesAReport: a stopped run leaves the verifier a report to read, never a missing one" \
  'until_true 20 "[ -f $reports/verify.json ]"'
check "StewardStopWithNoRunRecord_ReportSaysFail: a stopped run is a fail" '[ "$(report_status)" = fail ]'

echo "steward release of a dirty worktree still ends the detached run"
new_item dirty "$(held_gate dirty)"
rm -f ".flow/runs/$(slug "$item").json"
verify --start >/dev/null 2>&1
check "DirtyRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/dirty.count ]"'
dirty_pid="$(run_pid)"
check "DirtyRun_RecordNamesALiveProcess: the record must name the run, or its end below proves nothing" \
  'process_running "$dirty_pid"'
printf 'edited\n' >> "$worktree/README.md"
"$plugin/scripts/steward.sh" release "$item" >/dev/null 2>&1; dirty_release_code=$?
check "ReleaseOfADirtyWorktree_ExitsThree: the dirty check must refuse it, or the run's end below proves nothing" \
  '[ "$dirty_release_code" -eq 3 ]'
check "ReleaseOfADirtyWorktree_StillEndsTheVerifyRun: a gate that writes files cannot keep its own run going" \
  'until_true 30 "! process_running $dirty_pid"'

echo "steward stop and release leave another item's run alone"
new_item planted "$(held_gate planted)"
victim_item="$item"
verify --start >/dev/null 2>&1
check "VictimRun_GateStarts: the gate must be running, or the rows below prove nothing" \
  'until_true 20 "[ -s $work/planted.count ]"'
victim_pid="$(run_pid)"
victim_record="$reports/verify.run"
check "VictimRun_RecordNamesALiveProcess: the other item's run must be live, or its survival below proves nothing" \
  'process_running "$victim_pid"'
item="$("$local_adapter/create.sh" task "Detached planter" --size S --body x)"
"$plugin/scripts/next.sh" "$item" >/dev/null 2>&1
worktree="$("$plugin/scripts/steward.sh" find "$item")"
reports="$worktree/.flow/reports/$(slug "$item")"; mkdir -p "$reports"
rm -f ".flow/runs/$(slug "$item").json"
check "PlanterItem_HoldsAWorktree: stop and release must reach the planted record, or they prove nothing" '[ -n "$worktree" ]'
check "PlanterItem_IsAnotherItem: the record must name another item's run, or the run's survival proves nothing" \
  '[ "$item" != "$victim_item" ]'
cp "$victim_record" "$reports/verify.run"
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1
check "StewardStopOfAnItemWhoseRecordNamesAnotherItemsRun_LeavesThatRunGoing: a record names a run of its own item only" \
  'process_running "$victim_pid"'
"$plugin/scripts/steward.sh" release "$item" --force >/dev/null 2>&1
check "StewardReleaseOfAnItemWhoseRecordNamesAnotherItemsRun_LeavesThatRunGoing: a record names a run of its own item only" \
  'process_running "$victim_pid"'
touch "$work/release-planted"

echo "steward release waits for a run that will not end, then gives up"
new_item stubborn "  ok: 'true'"
rm -f ".flow/runs/$(slug "$item").json"
stubborn_pid="$(fake_run stubborn ignore-term)"
write_run_record "$reports" "$stubborn_pid"
check "StubbornRun_IsLiveBeforeTheRelease: the run must be live, or the release's refusal below proves nothing" \
  'process_running "$stubborn_pid"'
"$plugin/scripts/steward.sh" release "$item" --force >/dev/null 2>"$work/stubborn.err"; stubborn_release_code=$?
check "ReleaseWithARunThatIgnoresTerm_ExitsOne: a run still going is a failed release" '[ "$stubborn_release_code" -eq 1 ]'
check "ReleaseWithARunThatIgnoresTerm_NamesTheRunStillGoing: the owner learns which process holds the worktree" \
  'grep -qw "$stubborn_pid" "$work/stubborn.err"'
check "ReleaseWithARunThatIgnoresTerm_LeavesTheWorktreeClaimed: no worktree is reset under a run that still works in it" \
  '[ "$("$plugin/scripts/steward.sh" find "$item")" = "$worktree" ]'
kill -9 -- -"$stubborn_pid" 2>/dev/null || kill -9 "$stubborn_pid" 2>/dev/null

echo "a verify.run field that holds a command runs nothing"
new_item tampered "  ok: 'true'"
# The scripts run under bash, which runs a command in an array subscript in arithmetic, as the
# macOS /bin/sh (bash 3.2) does; dash does not, so a run under it would pass on nothing.
check "Bash_RunsACommandInAnArraySubscript: the shell must be one the tampered field can reach, or the rows below prove nothing" \
  'subscript="a[\$(touch $work/bash-ran)]" bash -c ": \$((subscript))" 2>/dev/null; [ -f "$work/bash-ran" ]'
tampered_pid="$(fake_run tampered)"
# --start reads limit only for a run it starts, so a limit row runs under --wait alone.
for tampered_row in "started --wait" "started --start" "limit --wait"; do
  tampered_field="${tampered_row% *}"; verify_mode="${tampered_row#* }"
  marker="$work/ran-$tampered_field$verify_mode"
  if [ "$tampered_field" = started ]; then write_run_record "$reports" "$tampered_pid" "a[\$(touch $marker)]"
  else write_run_record "$reports" "$tampered_pid" "" "a[\$(touch $marker)]"; fi
  if [ "$verify_mode" = --wait ]; then (cd "$worktree" && bash "$plugin/scripts/verify.sh" "$item" --wait 1) >/dev/null 2>&1
  else (cd "$worktree" && bash "$plugin/scripts/verify.sh" "$item" --start) >/dev/null 2>&1; fi
  check "VerifyRunFieldHoldingACommand_RunsNothing [$tampered_field $verify_mode]: a field reaches arithmetic only as digits" \
    '[ ! -e "$marker" ]'
done
touch "$work/release-tampered"

echo "verify --start never writes through a link"
for linked_name in verify.out verify.log; do
  new_item "linked-$(printf '%s' "$linked_name" | tr . -)" "  ok: 'true'"
  printf 'untouched\n' > "$work/target-$linked_name"
  ln -s "$work/target-$linked_name" "$reports/$linked_name"
  verify --start >/dev/null 2>&1
  wait_until_ended
  check "StartWithALinkAtTheOutput_LeavesTheLinkTargetUntouched [$linked_name]: the run writes only its own file" \
    '[ "$(cat "$work/target-$linked_name")" = untouched ]'
  check "StartWithALinkAtTheOutput_WritesAFile [$linked_name]: the run makes its own output where the link was" \
    '[ -f "$reports/$linked_name" ]'
  check "StartWithALinkAtTheOutput_ReplacesTheLink [$linked_name]: the link is replaced, not followed" \
    '[ ! -L "$reports/$linked_name" ]'
done

echo "health counts a detached verify run only in the item's own worktree"
own_worktree="$work/own/wt-1"; other_worktree="$work/other/wt-1"; mkdir -p "$own_worktree" "$other_worktree"
for run_worktree in own other; do
  eval "run_cwd=\"\$${run_worktree}_worktree\""
  printf '999991\t%s\tsh %s/scripts/verify.sh local:task/1 --detached\n' "$run_cwd" "$plugin" > "$work/procs-$run_worktree"
done
check "HealthAliveWithTheRunInTheItemsWorktree_FindsTheRun: the row must count in its own worktree, or the next check proves nothing" \
  '[ -n "$(python3 "$plugin/scripts/_health.py" alive "$work/procs-own" local:task/1 "$own_worktree")" ]'
check "HealthAliveWithTheSameItemsRunInAnotherWorktree_FindsNothing: another repo's run of the same id keeps no dead run alive" \
  '[ -z "$(python3 "$plugin/scripts/_health.py" alive "$work/procs-other" local:task/1 "$own_worktree")" ]'

if [ "$fails" -eq 0 ]; then echo "verify-detached: ok"; else echo "verify-detached: $fails failed"; exit 1; fi
