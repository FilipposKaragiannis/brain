#!/bin/sh
# verify-ends.sh: who ends a detached verify run, and when they give up, on the local adapter in
# throwaway repos. steward stop exits 1 when the run ignores TERM past its wait, with a run record
# (which it still clears) or without one; stop and release leave a run of the item's id that works
# outside the item's worktree; _health.py works-in says whether a process works in a folder; and
# verify.sh refuses a --base that git would read as an option. Each stand-in run waits for a file
# the test creates, or for the test's folder to go, so none outlives the test.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
# On exit every stand-in run is let go.
trap 'for run_name in stubborn elsewhere inside nested outside gone; do touch "$work/release-$run_name"; done; [ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
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
  '[ -f "$(run_file "$item")" ]'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1; recorded_stop_code=$?
check "StopWithARecordAndARunThatIgnoresTerm_ExitsOne: a run still going is a failed stop" '[ "$recorded_stop_code" -eq 1 ]'
check "StopWithARecordAndARunThatIgnoresTerm_ClearsTheRecord: health must not resume a stopped item" \
  '[ ! -f "$(run_file "$item")" ]'
check "StubbornRun_OutlivesTheFirstStop: the run must still go, or the next stop's exit proves nothing" \
  'process_running "$stubborn_pid"'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1; recordless_stop_code=$?
check "StopWithNoRecordAndARunThatIgnoresTerm_ExitsOne: a verify run started by hand that will not end is still a failed stop" \
  '[ "$recordless_stop_code" -eq 1 ]'
kill -9 -- -"$stubborn_pid" 2>/dev/null || kill -9 "$stubborn_pid" 2>/dev/null

echo "steward stop and release leave a run of the item's id that works outside the worktree"
new_item elsewhere "  ok: 'true'"
rm -f "$(run_file "$item")"
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

if [ "$fails" -eq 0 ]; then echo "verify-ends: ok"; else echo "verify-ends: $fails failed"; exit 1; fi
