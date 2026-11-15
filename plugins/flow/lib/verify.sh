#!/bin/sh
# The detached verify run (scripts/verify.sh --start): its record and its end. Sourced after
# lib/flow.sh by scripts/verify.sh and scripts/steward.sh. The record is <reports>/verify.run, one
# `key value` line each: pid (the run's own session and process group), started (epoch seconds),
# head (the short commit it checks) and limit (seconds).

# The seconds a stopped run gets to end before what is left of its group is killed.
VERIFY_STOP_GRACE=10
# The seconds release and stop wait for a run they end: the run's own grace for its checks, twice.
VERIFY_END_WAIT=$((VERIFY_STOP_GRACE * 2))

verify_run_file() { printf '%s/verify.run' "$1"; }

# verify_run_record <reports> <pid> <started> <head> <limit>: writes the record to a new file
# mktemp makes, never through a link left at a name, and renames it in. verify.sh --start calls it.
verify_run_record() {
  record_temp="$(mktemp "$1/.verify.run.XXXXXX")" &&
    printf 'pid %s\nstarted %s\nhead %s\nlimit %s\n' "$2" "$3" "$4" "$5" > "$record_temp" && mv -f "$record_temp" "$(verify_run_file "$1")"
}

# verify_run_start <reports> <run output> <limit> <item> <base or empty>: starts the item's detached
# run (verify.sh <item> --detached [--base <base>]) in its own session, its output to the run
# output, records it and prints its pid. Says why on stderr and returns 1 when it cannot start or
# record the run. verify.sh --start calls it.
verify_run_start() {
  spawned_started="$(date +%s)"; spawned_head="$(git rev-parse --short HEAD)"
  spawned_pid="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" spawn "$2" sh "$FLOW_PLUGIN/scripts/verify.sh" "$4" --detached ${5:+--base "$5"})" &&
    [ -n "$spawned_pid" ] || { echo "flow: could not start the verify run of $4" >&2; return 1; }
  verify_run_record "$1" "$spawned_pid" "$spawned_started" "$spawned_head" "$3" ||
    { echo "flow: could not record the verify run of $4 (pid $spawned_pid)" >&2; return 1; }
  printf '%s' "$spawned_pid"
}

# verify_run_field <reports> <key>: one field of the record, empty when there is none or when it
# holds more than the field may: hex digits for head, digits for the numbers. Anyone in the worktree
# can write the record, and the numbers reach shell arithmetic, where bash runs a command in an
# array subscript.
verify_run_field() {
  recorded_field="$(sed -n "s/^$2 //p" "$(verify_run_file "$1")" 2>/dev/null | head -n 1)"
  case "$2" in head) field_characters=0-9a-f ;; *) field_characters=0-9 ;; esac
  case "$recorded_field" in ''|*[!$field_characters]*) ;; *) printf '%s' "$recorded_field" ;; esac
}

# process_running <pid>: true while the process runs (a zombie has ended).
process_running() {
  case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in ''|Z*) return 1 ;; esac
}

# verify_run_live <reports> <item>: the pid of the item's recorded run while it still runs, else
# nothing and 1. The process must still be verify.sh's detached run of that item, so neither a pid
# used again nor the pid of another item's run is taken for it.
verify_run_live() {
  live_pid="$(verify_run_field "$1" pid)"
  [ -n "$live_pid" ] && process_running "$live_pid" || return 1
  case "$(ps -o command= -p "$live_pid" 2>/dev/null)" in *"verify.sh $2 --detached"*) printf '%s' "$live_pid" ;; *) return 1 ;; esac
}

# verify_run_end <item> <worktree>: ends the item's detached run in the worktree when it still runs:
# TERM to its process group, so its checks end too, and the run writes its fail report. Prints the
# pid of the run it ended, nothing when none ran. A run whose working folder is not in the worktree
# is another repository's run of the same item id, and is left alone, as the health job leaves it.
# When it still runs after VERIFY_END_WAIT, says so on stderr and returns 1. steward.sh release
# and stop call it.
verify_run_end() {
  [ -n "$2" ] || return 0
  ended_pid="$(verify_run_live "$(reports_dir "$1" "$2")" "$1")" || return 0
  python3 -I "$FLOW_PLUGIN/scripts/_health.py" works-in "$ended_pid" "$2" || return 0
  kill -s TERM -- "-$ended_pid" 2>/dev/null
  end_waited=0
  while process_running "$ended_pid"; do
    [ "$end_waited" -lt "$VERIFY_END_WAIT" ] || { echo "flow: the verify run of $1 (process $ended_pid) did not end yet; try again once it has" >&2; return 1; }
    sleep 1; end_waited=$((end_waited + 1))
  done
  printf '%s' "$ended_pid"
}

# verify_signal_rest_of_group <signal>: the signal to every process of the calling shell's group
# but itself, the detached run's group, as it leads one. A lone command substitution adds no shell
# of its own to the group, and pgrep never lists itself.
verify_signal_rest_of_group() {
  for group_pid in $(pgrep -g "$$"); do [ "$group_pid" = "$$" ] || kill -s "$1" "$group_pid" 2>/dev/null; done
}
# verify_stop_group: TERM to the rest of the detached run's group, then KILL to what is left after
# VERIFY_STOP_GRACE. verify.sh --detached calls it at the limit or on a signal.
verify_stop_group() {
  verify_signal_rest_of_group TERM
  grace_waited=0
  while [ "$(pgrep -g "$$")" != "$$" ] && [ "$grace_waited" -lt "$VERIFY_STOP_GRACE" ]; do sleep 1; grace_waited=$((grace_waited + 1)); done
  verify_signal_rest_of_group KILL
}

# verify_running_check <log>: the check the log shows running last, as its header says it
# (`gate flow: sh tests/run.sh`), empty before the first.
verify_running_check() { sed -n 's/^== //p' "$1" 2>/dev/null | tail -n 1; }
