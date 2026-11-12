#!/bin/sh
# The detached verify run (scripts/verify.sh --start): its record and its end. Sourced after
# lib/flow.sh by scripts/verify.sh and scripts/steward.sh. The record is <reports>/verify.run, one
# `key value` line each: pid (the run's own session and process group), started (epoch seconds),
# head (the short commit it checks) and limit (seconds).

# The seconds a stopped run gets to end before what is left of its group is killed.
VERIFY_STOP_GRACE=10

verify_run_file() { printf '%s/verify.run' "$1"; }

# verify_run_field <reports> <key>: one field of the record, empty when there is none.
verify_run_field() { sed -n "s/^$2 //p" "$(verify_run_file "$1")" 2>/dev/null | head -n 1; }

# process_running <pid>: true while the process runs (a zombie has ended).
process_running() {
  case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in ''|Z*) return 1 ;; esac
}

# verify_run_live <reports>: the pid of the recorded run while it still runs, else nothing and 1.
# The process must still be verify.sh's detached run, so a pid used again is never taken for it.
verify_run_live() {
  vl_pid="$(verify_run_field "$1" pid)"
  case "$vl_pid" in ''|*[!0-9]*) return 1 ;; esac
  process_running "$vl_pid" || return 1
  case "$(ps -o command= -p "$vl_pid" 2>/dev/null)" in *verify.sh*--detached*) printf '%s' "$vl_pid" ;; *) return 1 ;; esac
}

# verify_run_stop <reports>: end the recorded run when it still runs: TERM to its process group, so
# its checks end too; the run writes its fail report. Waits for it up to twice the grace the run
# gives its own checks. Returns 1 when it still runs then.
verify_run_stop() {
  vs_pid="$(verify_run_live "$1")" || return 0
  kill -s TERM -- "-$vs_pid" 2>/dev/null
  vs_waited=0
  while process_running "$vs_pid"; do
    [ "$vs_waited" -lt $((VERIFY_STOP_GRACE * 2)) ] || return 1
    sleep 1; vs_waited=$((vs_waited + 1))
  done
}

# verify_running_check <log>: the check the log shows running last, as its header says it
# (`gate flow: sh tests/run.sh`), empty before the first.
verify_running_check() { sed -n 's/^== //p' "$1" 2>/dev/null | tail -n 1; }
