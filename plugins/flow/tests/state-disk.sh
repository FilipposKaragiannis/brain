#!/bin/sh
# state-disk.sh: how a flow record write meets the disk and other writers, on the local adapter in
# a throwaway repo. A write waits for the item's lock and lands once it is free; two writers at once
# both land in every round; a lock held past the wait says try again; state.dir is made by the first
# write; a write leaves no temporary and takes the umask; a link planted where the old fixed
# temporary name went is never written through.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
new_repo records
cp .flow/config.yaml "$work/config.saved"
tracker_state_is none

lock_holder_start_tries=100
# The holder lets go once the sandbox removes the work folder, so a cut run leaves no holder.
lock_holder_poll_seconds=0.1
hold_lock() { # hold_lock <item> <seconds>: holds until let go, the seconds pass or the work folder goes
  rm -f "$work/lock.held"; mkdir -p .flow/locks
  python3 -c 'import fcntl,os,sys,time
handle=open(sys.argv[1],"a"); fcntl.flock(handle, fcntl.LOCK_EX); open(sys.argv[2],"w").close()
deadline=time.time()+float(sys.argv[3])
while time.time()<deadline and os.path.exists(sys.argv[2]): time.sleep(float(sys.argv[4]))' \
    ".flow/locks/$(slug "$1").lock" "$work/lock.held" "$2" "$lock_holder_poll_seconds" &
  lock_holder=$!
  tries=0; while [ ! -f "$work/lock.held" ] && [ "$tries" -lt "$lock_holder_start_tries" ]; do sleep 0.1; tries=$((tries + 1)); done
  [ -f "$work/lock.held" ]
}
let_go_of_lock() { kill "$lock_holder" 2>/dev/null; wait "$lock_holder" 2>/dev/null; lock_holder=; }

echo "a write waits for the item's lock"
waiting="$(new_task "Waits for the lock")"
record set "$waiting" step=plan >/dev/null 2>&1
lock_held_seconds_within_the_wait=30
lock_wait_seconds="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _state_schema as schema; print(schema.LOCK_TRIES * schema.LOCK_RETRY_SECONDS)' "$plugin/scripts")"
writer_poll_seconds=0.1
writer_polls_within_half_the_wait="$(python3 -c 'import sys; print(int(float(sys.argv[1]) / 2 / float(sys.argv[2])))' "$lock_wait_seconds" "$writer_poll_seconds")"
if hold_lock "$waiting" "$lock_held_seconds_within_the_wait"; then
  record set "$waiting" step=review >/dev/null 2>&1 & waiting_writer=$!
  polls=0
  while kill -0 "$waiting_writer" 2>/dev/null && [ "$polls" -lt "$writer_polls_within_half_the_wait" ]; do
    sleep "$writer_poll_seconds"; polls=$((polls + 1))
  done
  step_while_held="$(record get "$waiting" step)"
  let_go_of_lock
  wait "$waiting_writer"
fi
check "WriteWhileTheLockIsHeld_WritesNothingUntilItIsFree: a write merges only under the item's lock, so it cannot overwrite a writer that holds it" \
  '[ "$step_while_held" = plan ]'
check "WriteWhileTheLockIsHeld_LandsOnceItIsFree: a write that waited for the lock still lands" '[ "$(record get "$waiting" step)" = review ]'

echo "two writers at once both land, round after round"
raced="$(new_task "Two writers")"
record set "$raced" step=plan >/dev/null 2>&1
lock_rounds=25
round=1; lost_steps=0; lost_events=0
while [ "$round" -le "$lock_rounds" ]; do
  record set "$raced" "step=step-$round" >/dev/null 2>&1 & record set "$raced" "last_event=event-$round" >/dev/null 2>&1 & wait
  [ "$(record get "$raced" step)" = "step-$round" ] || lost_steps=$((lost_steps + 1))
  [ "$(record get "$raced" last_event)" = "event-$round" ] || lost_events=$((lost_events + 1))
  round=$((round + 1))
done
check "TwoWritersOfDifferentKeys_LoseNoStepInAnyRound: each write merges under the item's lock, so the other key's write never drops it" '[ "$lost_steps" -eq 0 ]'
check "TwoWritersOfDifferentKeys_LoseNoEventInAnyRound: each write merges under the item's lock, so the other key's write never drops it" '[ "$lost_events" -eq 0 ]'
check "TwoWritersOfDifferentKeys_LeaveARecordThatParses: a write replaces the record whole, never in part" \
  'record show "$raced" | python3 -c "import json,sys; json.load(sys.stdin)"'
fresh="$(new_task "Two first writes")"
record set "$fresh" step=plan >/dev/null 2>&1 & record set "$fresh" last_event=first >/dev/null 2>&1 & wait
check "TwoFirstWritesAtOnce_KeepTheStep: the second first write finds the record and merges into it" '[ "$(record get "$fresh" step)" = plan ]'
check "TwoFirstWritesAtOnce_KeepTheEvent: the second first write finds the record and merges into it" '[ "$(record get "$fresh" last_event)" = first ]'

echo "a busy lock"
locked="$(new_task "Busy lock")"
record set "$locked" step=plan >/dev/null 2>&1
lock_held_seconds_past_any_wait=600
code=lock-never-held
hold_lock "$locked" "$lock_held_seconds_past_any_wait" && { record set "$locked" step=review >/dev/null 2>&1; code=$?; }
let_go_of_lock
check "LockHeldByAnotherWrite_ExitsSeventyFive: a write that cannot take the item's lock says try again" '[ "$code" -eq 75 ]'
check "LockHeldByAnotherWrite_LeavesTheRecordAsItWas: a write that never took the lock changes nothing" '[ "$(record get "$locked" step)" = plan ]'

echo "how a write lands on disk"
fresh_state_dir="$work/not-yet/records"
printf 'state:\n  dir: %s\n' "$fresh_state_dir" >> .flow/config.yaml
landed="$(new_task "Lands on disk")"
(umask 022 && record set "$landed" step=plan >/dev/null 2>&1)
check "MissingStateDir_IsMadeByTheFirstWrite: the first write makes state.dir and its record" '[ -f "$(record path "$landed")" ]'
check "Write_LeavesOnlyTheRecordInStateDir: a write renames its temporary into place" \
  '[ "$(ls -A "$fresh_state_dir")" = "$(basename "$(record path "$landed")")" ]'
(umask 022 && : > "$work/plain-write")
mode_of() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
check "RecordFileUnderUmask022_TakesTheModeAPlainWriteGives: the record is as readable as the file it replaced" \
  '[ "$(mode_of "$(record path "$landed")")" = "$(mode_of "$work/plain-write")" ]'
record set "$landed" "run:=$run_record" >/dev/null 2>&1
check "Write_LeavesOnlyTheRunFileInTheRunsFolder: a view is renamed into place too" \
  '[ "$(ls -A .flow/runs)" = "$(basename "$(run_file "$landed")")" ]'
cp "$work/config.saved" .flow/config.yaml

echo "a link planted at the old fixed temporary name"
pids_a_write_may_skip=3000
plant_links() { # plant_links <file> <target>: prints the first pid it planted for
  python3 -c 'import os,sys
folder,name,target,window=os.path.dirname(sys.argv[1]),os.path.basename(sys.argv[1]),sys.argv[2],int(sys.argv[3])
first=os.getpid()
for pid in range(first,first+window): os.symlink(target,"%s/.%s.%d.tmp"%(folder,name,pid))
print(first)' "$1" "$2" "$pids_a_write_may_skip"
}
next_pid() { true & echo "$!"; wait "$!"; }
window_covered_the_write() { # window_covered_the_write <first planted pid> <a pid started after the write>
  [ "$2" -gt "$1" ] && [ "$2" -lt $(($1 + pids_a_write_may_skip)) ]
}
linked="$(new_task "Planted link")"
record set "$linked" step=plan >/dev/null 2>&1
printf 'kept\n' > "$work/record-victim"
first_planted="$(plant_links "$(record path "$linked")" "$work/record-victim")"
record set "$linked" step=review >/dev/null 2>&1
after_write="$(next_pid)"
check "PlantedLinkAtTheRecordsOldTemporaryName_IsNotWrittenThrough: a record write makes its own new temporary, never one someone else placed" \
  'window_covered_the_write "$first_planted" "$after_write" && [ "$(cat "$work/record-victim")" = kept ]'
mkdir -p .flow/runs
printf 'kept\n' > "$work/run-victim"
first_planted="$(plant_links "$(run_file "$linked")" "$work/run-victim")"
record set "$linked" "run:=$run_record" >/dev/null 2>&1
after_write="$(next_pid)"
check "PlantedLinkAtTheRunFilesOldTemporaryName_IsNotWrittenThrough: a view write makes its own new temporary, never one someone else placed" \
  'window_covered_the_write "$first_planted" "$after_write" && [ "$(cat "$work/run-victim")" = kept ]'

[ "$fails" -eq 0 ] && { echo "state-disk: ok"; exit 0; }
echo "state-disk: $fails failed"; exit 1
