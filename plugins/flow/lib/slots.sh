#!/bin/sh
# A pool of slots that caps the passes live at once across every run of a job: <pool>/<n>, n from
# 1 to the cap, each a directory holding the pid of the run that took it. Sourced by
# jobs/comments.sh after jobs/_job.sh: a slot is stale when job_alive fails on its pid, as for the
# job lock, and is then taken over. A slot whose pid is not written yet is held.
SLOT_POLL_SECONDS=1
# slot_try <pool> <count> <pid>: takes a free or stale slot of the first <count> for <pid> and
# prints its path; returns 1 when every one is held.
slot_try() {
  mkdir -p "$1"
  slot_number=1
  while [ "$slot_number" -le "$2" ]; do
    slot_path="$1/$slot_number"; slot_number=$((slot_number + 1))
    if ! mkdir "$slot_path" 2>/dev/null; then
      slot_holder="$(cat "$slot_path/pid" 2>/dev/null)"
      { [ -n "$slot_holder" ] && ! job_alive "$slot_holder"; } || continue
      rm -rf "$slot_path"; mkdir "$slot_path" 2>/dev/null || continue
    fi
    printf '%s\n' "$3" > "$slot_path/pid"; printf '%s' "$slot_path"; return 0
  done
  return 1
}
# slot_take <pool> <count> <pid>: slot_try until a slot is free, one poll a second; prints its path.
slot_take() {
  until slot_try "$1" "$2" "$3"; do sleep "$SLOT_POLL_SECONDS"; done
}
# slot_give <slot>: frees the slot.
slot_give() { rm -rf "$1"; }
# slot_give_all <pool> <pid>: frees every slot of the pool <pid> holds.
slot_give_all() {
  for slot_path in "$1"/*; do
    [ "$(cat "$slot_path/pid" 2>/dev/null)" != "$2" ] || rm -rf "$slot_path"
  done
}
