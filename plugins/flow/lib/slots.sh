#!/bin/sh
# A pool of slots that caps the passes live at once across every run of a job: <pool>/<n>, n from
# 1 to the cap, each a symbolic link whose target is the pid of the run that took it, so a slot is
# made with its pid in one step. Sourced by jobs/comments.sh after jobs/_job.sh: a slot is stale
# when job_alive fails on its pid, as for the job lock, and is then taken over (slot_take_over).
SLOT_POLL_SECONDS=1
# slot_try <pool> <count> <pid>: takes a free or stale slot of the first <count> for <pid> and
# prints its path; returns 1 when every one is held.
slot_try() {
  mkdir -p "$1"
  try_number=1
  while [ "$try_number" -le "$2" ]; do
    try_path="$1/$try_number"; try_number=$((try_number + 1))
    ln -sn "$3" "$try_path" 2>/dev/null || slot_take_over "$try_path" "$3" || continue
    printf '%s' "$try_path"; return 0
  done
  return 1
}
# slot_take_over <slot> <pid>: takes the slot for <pid> when the run holding it is gone. The stale
# slot goes only under <slot>.takeover and only while it still names the dead holder, so two runs
# that saw the same dead holder never both take it.
slot_take_over() {
  stale_holder="$(readlink "$1" 2>/dev/null)"
  [ -n "$stale_holder" ] && ! job_alive "$stale_holder" && slot_guard_take "$1.takeover" "$2" || return 1
  [ "$(readlink "$1" 2>/dev/null)" != "$stale_holder" ] || rm -f "$1"
  rm -f "$1.takeover"
  ln -sn "$2" "$1" 2>/dev/null
}
# slot_guard_take <guard> <pid>: takes the guard for <pid>, a symbolic link to it like a slot, so a
# taker stopped before it lets the guard go leaves one that the next taker clears instead of
# waiting on it forever; returns 1 while a live run holds it.
slot_guard_take() {
  ln -sn "$2" "$1" 2>/dev/null && return 0
  guard_holder="$(readlink "$1" 2>/dev/null)"
  [ -n "$guard_holder" ] && ! job_alive "$guard_holder" || return 1
  [ "$(readlink "$1" 2>/dev/null)" != "$guard_holder" ] || rm -f "$1"
  ln -sn "$2" "$1" 2>/dev/null
}
# slot_take <pool> <count> <pid>: slot_try until a slot is free, one poll a second; prints its path.
slot_take() {
  until slot_try "$1" "$2" "$3"; do sleep "$SLOT_POLL_SECONDS"; done
}
# slot_give <slot>: frees the slot.
slot_give() { rm -f "$1"; }
# slot_give_all <pool> <pid>: frees every slot of the pool <pid> holds.
slot_give_all() {
  for given_path in "$1"/*; do
    [ "$(readlink "$given_path" 2>/dev/null)" != "$2" ] || rm -f "$given_path"
  done
}
