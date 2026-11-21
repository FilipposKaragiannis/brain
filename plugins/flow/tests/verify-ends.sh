#!/bin/sh
# verify-ends.sh: who ends a detached verify run, and when they give up, on the local adapter in
# throwaway repos. steward stop exits 1 when the run ignores TERM past its wait, with a run record
# (which it still clears) or without one; stop and release leave a run of the item's id that works
# outside the item's worktree; stop names the verify run it ended; _health.py works-in says whether a
# process works in a folder; verify.sh refuses a --base that git would read as an option; --start
# exits 1 when it cannot start or record the run; and the plain run never writes through a link. Each stand-in run waits for a file
# the test creates, or for the test's folder to go, so none outlives the test.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
# The sandbox removes the folder on exit, which lets every held gate and stand-in run go.
. "$here/_verify_fixture.sh"

echo "verify.sh refuses a --base that git would read as an option"
new_item optioned "  ok: 'true'"
for refused_base in -x "--output=$work/written-by-git"; do
  verify --base "$refused_base" >/dev/null 2>&1; refused_code=$?
  check "VerifyWithABaseThatStartsWithADash_ExitsTwo [$refused_base]: 2 is a bad argument, never a fail of the checks" \
    '[ "$refused_code" -eq 2 ]'
done
check "VerifyWithAnOutputOptionAsTheBase_WritesNoFile: git never takes the name, so it writes nowhere" \
  '[ ! -e "$work/written-by-git" ]'

echo "steward stop gives up on a run that ignores TERM, with a run record and without one"
new_item stubborn "  ok: 'true'"
record_a_dead_agent
stubborn_pid="$(fake_run stubborn ignore-term)"
write_run_record "$reports" "$stubborn_pid"
check "StubbornRun_IsLiveBeforeTheStop: the run must be live, or the stop's exit below proves nothing" \
  'process_running "$stubborn_pid"'
check "StubbornItem_HasARunRecord: the first stop must find a record, or it is the no-record row twice" \
  '[ -n "$(state "$item" run)" ]'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1; recorded_stop_code=$?
check "StopWithARecordAndARunThatIgnoresTerm_ExitsOne: a run still going is a failed stop" '[ "$recorded_stop_code" -eq 1 ]'
check "StopWithARecordAndARunThatIgnoresTerm_ClearsTheRecord: health must not resume a stopped item" \
  '[ -z "$(state "$item" run)" ]'
check "StubbornRun_OutlivesTheFirstStop: the run must still go, or the next stop's exit proves nothing" \
  'process_running "$stubborn_pid"'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1; recordless_stop_code=$?
check "StopWithNoRecordAndARunThatIgnoresTerm_ExitsOne: a verify run started by hand that will not end is still a failed stop" \
  '[ "$recordless_stop_code" -eq 1 ]'
kill -9 -- -"$stubborn_pid" 2>/dev/null || kill -9 "$stubborn_pid" 2>/dev/null

echo "steward stop and release leave a run of the item's id that works outside the worktree"
new_item elsewhere "  ok: 'true'"
end_run "$item"
mkdir -p "$work/another-repository"
elsewhere_pid="$(run_cwd="$work/another-repository" fake_run elsewhere)"
write_run_record "$reports" "$elsewhere_pid"
check "ElsewhereRun_IsLiveBeforeTheStop: the run must be live, or its survival below proves nothing" \
  'process_running "$elsewhere_pid"'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1
check "StopWhoseRecordNamesARunOutsideTheWorktree_LeavesThatRunGoing: another repository's run of the same id is not this item's" \
  'process_running "$elsewhere_pid"'
"$plugin/scripts/steward.sh" release "$item" --force >/dev/null 2>&1
check "ReleaseWhoseRecordNamesARunOutsideTheWorktree_LeavesThatRunGoing: another repository's run of the same id is not this item's" \
  'process_running "$elsewhere_pid"'
touch "$work/release-elsewhere"

echo "_health.py works-in says whether a process works in a folder"
works_in() { python3 "$plugin/scripts/_health.py" works-in "$1" "$2" >/dev/null 2>&1; }
folder="$work/folder"; mkdir -p "$folder/nested" "$work/outside"
inside_pid="$(run_cwd="$folder" fake_run inside)"
nested_pid="$(run_cwd="$folder/nested" fake_run nested)"
outside_pid="$(run_cwd="$work/outside" fake_run outside)"
gone_pid="$(run_cwd="$folder" fake_run gone)"; touch "$work/release-gone"
check "GoneRun_HasEnded: the pid must be gone, or the gone row below proves nothing" 'until_true 20 "! process_running $gone_pid"'
check "WorksInWithAProcessInTheFolder_ExitsZero: a run in the worktree is the item's" 'works_in "$inside_pid" "$folder"'
check "WorksInWithAProcessInAFolderUnderIt_ExitsZero: a run in a subfolder of the worktree is the item's" \
  'works_in "$nested_pid" "$folder"'
check "WorksInWithAProcessElsewhere_ExitsOne: a run in another folder is not the item's" '! works_in "$outside_pid" "$folder"'
check "WorksInWithAProcessThatIsGone_ExitsOne: a working folder that cannot be read is no match" '! works_in "$gone_pid" "$folder"'

echo "steward stop names the verify run it ended, with a run record and without one"
new_item said "  ok: 'true'"
record_a_dead_agent
recorded_said_pid="$(fake_run said)"
write_run_record "$reports" "$recorded_said_pid"
stop_said="$("$plugin/scripts/steward.sh" stop "$item" 2>&1)"; said_stop_code=$?
check "StopWithARecordAndAVerifyRunThatEnds_ExitsZero: a run that ended is a stop that worked" '[ "$said_stop_code" -eq 0 ]'
check "StopWithARecordAndAVerifyRunThatEnds_NamesTheVerifyPid: the owner sees which run it ended" \
  'printf "%s" "$stop_said" | grep -qw "$recorded_said_pid"'
recordless_said_pid="$(fake_run said-again)"
write_run_record "$reports" "$recordless_said_pid"
check "SaidAgainItem_HasNoAgentRecord: the first stop cleared it, or this is the record row twice" '[ -z "$(state "$item" run)" ]'
stop_said="$("$plugin/scripts/steward.sh" stop "$item" 2>&1)"
check "StopWithNoRecordAndAVerifyRunThatEnds_NamesTheVerifyPid: a verify run started by hand is named all the same" \
  'printf "%s" "$stop_said" | grep -qw "$recordless_said_pid"'

echo "verify.sh --start exits 1 when it cannot start or record the run"
new_item unspawned "  ok: 'true'"
# A python3 in front of the real one that fails the spawn and runs everything else.
mkdir -p "$work/failing-spawn"
printf '#!/bin/sh\ncase " $* " in *" spawn "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v python3)" > "$work/failing-spawn/python3"
chmod +x "$work/failing-spawn/python3"
unspawned_err="$(PATH="$work/failing-spawn:$PATH" verify --start 2>&1 >/dev/null)"; unspawned_code=$?
check "StartWhoseSpawnFails_ExitsOne: no run started is no start, never a quiet 0" '[ "$unspawned_code" -eq 1 ]'
check "StartWhoseSpawnFails_NamesTheItemOnStderr: the owner sees which item's run did not start" \
  'printf "%s" "$unspawned_err" | grep -qF "$item"'
check "StartWhoseSpawnFails_RecordsNoRun: a record of no run would have --wait wait on nothing" '[ ! -e "$reports/verify.run" ]'
new_item unrecorded "  ok: 'true'"
# A folder at the record's name: the record cannot be renamed in, whoever runs the test.
mkdir "$reports/verify.run"
unrecorded_err="$(verify --start 2>&1 >/dev/null)"; unrecorded_code=$?
check "StartWhoseRecordCannotBeWritten_ExitsOne: a run nobody can wait on or stop is no start" '[ "$unrecorded_code" -eq 1 ]'
check "StartWhoseRecordCannotBeWritten_NamesTheItemOnStderr: the owner sees which item's run went unrecorded" \
  'printf "%s" "$unrecorded_err" | grep -qF "$item"'
check "StartWhoseRecordCannotBeWritten_LeavesNoRecordBehind: a record inside the folder or a temporary one is a run nobody stops" \
  '[ -z "$(ls -A "$reports/verify.run")" ] && [ -z "$(find "$reports" -name ".verify.run.*")" ]'
# The run that started goes on unrecorded; its report says it is done.
check "UnrecordedRun_EndsWithAReport: the started run must end before the next section" 'until_true 60 "[ -s $reports/verify.json ]"'

echo "the plain verify run makes its log new, never through a link at its name"
new_item linked "  ok: 'true'"
printf 'kept\n' > "$work/log-target"
rm -f "$reports/verify.log" && ln -s "$work/log-target" "$reports/verify.log"
verify >/dev/null 2>&1
check "PlainRunWithALinkAtTheLog_LeavesTheLinkTargetUntouched: verify writes its own files, never one a link points to" \
  '[ "$(cat "$work/log-target")" = kept ]'

if [ "$fails" -eq 0 ]; then echo "verify-ends: ok"; else echo "verify-ends: $fails failed"; exit 1; fi
