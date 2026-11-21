#!/bin/sh
# A pool of slots that caps the passes live at once across every run of a job: <pool>/<n>, n from
# 1 to the cap, each a symbolic link whose target is the pid of the run that took it, so a slot is
# made with its pid in one step. Sourced by jobs/comments.sh after jobs/_job.sh: a slot is stale
# when job_alive fails on its pid, as for the job lock, and is then taken over (slot_take_over).
# <slot>.group names the process group of the pass's host session: a slot whose group still has a
# process stays held after its run ended, so a host that outlives a stopped run keeps its slot.
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
# slot_take_over <entry> <pid>: takes the entry, a slot or a guard, for <pid> when the run holding
# it is gone; returns 1 while a live run holds it.
slot_take_over() { slot_take_from "$1" "$2" "$(readlink "$1" 2>/dev/null)"; }
# slot_take_from <entry> <pid> <holder>: takes the entry for <pid> from the dead <holder> under the
# guard <entry>.<holder>, a symbolic link to the taker like a slot, so only one run takes an entry
# from a given holder. A guard whose taker died is taken over the same way, under its own guard,
# so an entry is removed only by the one run that holds its guard.
slot_take_from() {
  [ -n "$3" ] && ! job_alive "$3" && ! slot_group_alive "$1" || return 1
  ln -sn "$2" "$1.$3" 2>/dev/null || slot_take_over "$1.$3" "$2" || return 1
  [ "$(readlink "$1" 2>/dev/null)" != "$3" ] || rm -f "$1.group" "$1"
  rm -f "$1.$3"
  ln -sn "$2" "$1" 2>/dev/null
}
# slot_take <pool> <count> <pid>: slot_try until a slot is free, one poll a second; prints its path.
slot_take() {
  until slot_try "$1" "$2" "$3"; do sleep "$SLOT_POLL_SECONDS"; done
}
# slot_group_alive <slot>: true while a process of the host group <slot>.group names runs.
slot_group_alive() {
  read -r live_group 2>/dev/null < "$1.group" || return 1
  case "$live_group" in ''|*[!0-9]*|0|1) return 1 ;; esac
  group_running "$live_group"
}
# slot_holders <pool>: the pids of the runs that hold the pool's slots, comma-separated.
slot_holders() {
  for held_path in "$1"/*; do
    case "${held_path##*/}" in ''|*[!0-9]*) continue ;; esac
    readlink "$held_path" 2>/dev/null
  done | paste -sd, - | sed 's/,/, /g'
}
# slot_give <slot>: frees the slot.
slot_give() { rm -f "$1.group" "$1"; }
# slot_give_all <pool> <pid>: frees every slot of the pool <pid> holds whose host group is gone.
slot_give_all() {
  for given_path in "$1"/*; do
    [ "$(readlink "$given_path" 2>/dev/null)" != "$2" ] || slot_group_alive "$given_path" || rm -f "$given_path.group" "$given_path"
  done
}
