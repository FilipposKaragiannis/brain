#!/bin/sh
# Reading a process where ps may not run. Sourced by lib/verify.sh, scripts/jobs.sh, jobs/_job.sh
# and the console's demo.sh; scripts/_process.py does the same for the Python scripts.
# A sandbox refuses the setuid /bin/ps on macOS. ps is then read through pgrep, which needs no
# privilege, and a process group through python. pgrep -a lists the caller's own ancestors on
# macOS, and the whole command line on Linux, where ps is no setuid program. pgrep lists a zombie
# on Linux but none on macOS, so whether a process runs comes from /proc where there is one.

# ps_refused: true when ps cannot run here, as it lists not even this shell. Its exit code cannot
# say: a shell gives 126 for a command it cannot run, but 1 in a command substitution under set -e.
ps_refused() { [ -z "$(ps -o pid= -p "$$" 2>/dev/null)" ]; }
# pgrep_command <pid>: the command line pgrep lists for the running process, empty when none runs.
pgrep_command() { pgrep -alf . 2>/dev/null | sed -n "s/^$1 //p"; }
# proc_state <pid>: the state /proc/<pid>/stat gives, its field after the name in parentheses;
# empty when none runs.
proc_state() { sed -n 's/.*) \([A-Za-z]\) .*/\1/p' "/proc/$1/stat" 2>/dev/null; }
# state_running <state>: true for the state of a process that runs (a zombie has ended).
state_running() { case "$(printf '%s' "$1" | tr -d ' ')" in ''|Z*) return 1 ;; esac; }
# listed_running <pid>: process_running where ps cannot run.
listed_running() {
  [ -d /proc/self ] || { [ -n "$(pgrep_command "$1")" ]; return; }
  state_running "$(proc_state "$1")"
}
# process_running <pid>: true while the process runs.
process_running() {
  process_state="$(ps -o stat= -p "$1" 2>/dev/null)" || process_state=""
  [ -n "$process_state" ] || ! ps_refused || { listed_running "$1"; return; }
  state_running "$process_state"
}
# process_command <pid>: the process's command line, empty when none runs.
process_command() {
  ps_command="$(ps -o command= -p "$1" 2>/dev/null)" || ps_command=""
  [ -n "$ps_command" ] || ! ps_refused || { pgrep_command "$1"; return; }
  printf '%s' "$ps_command"
}
# process_group <pid>: the process group the process is in, empty when none runs.
process_group() {
  ps_group="$(ps -o pgid= -p "$1" 2>/dev/null)" || ps_group=""
  [ -n "$ps_group" ] || ! ps_refused || { python3 -I -c 'import os, sys
try:
    print(os.getpgid(int(sys.argv[1])))
except (OSError, ValueError):
    pass' "$1"; return; }
  printf '%s' "$ps_group" | tr -d ' '
}
# leads_own_group: true when the calling shell leads its process group, as the run --start starts
# does.
leads_own_group() { [ "$(process_group "$$")" = "$$" ]; }
