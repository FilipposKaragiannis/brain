#!/bin/sh
# sessions.sh: which process holds a worktree, as scripts/_health.py alive says, from a process
# list and Claude's session files in a throwaway home. Given the idle seconds, a session a person
# started that has been idle that long does not hold the worktree; one idle for less, one running
# a shell command, one with no status, and an unattended agent still do, and without the idle
# seconds every session does. A busy session beside an idle one is the one named. session reads
# the status of a session running a shell command as busy and of one waiting on its user as idle.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

IDLE_AFTER_SECONDS=1800
LONG_IDLE_SECONDS=7200
SHORT_IDLE_SECONDS=600
# Process ids above any the system gives out, so ps knows none of them.
PERSON_PID=4000001; AGENT_PID=4000002; SECOND_PID=4000003
item="local:task/1"
held="$work/held-worktree"; mkdir -p "$held" "$HOME/.claude/sessions"
listed="$work/processes.list"
health() { python3 -I "$plugin/scripts/_health.py" "$@"; }
# lists <pid> <command>...: the process list holds each pair as a process working in the worktree.
lists() { : > "$listed"; while [ $# -ge 2 ]; do printf '%s\t%s\t%s\n' "$1" "$held" "$2" >> "$listed"; shift 2; done; }
# status <pid> <status> <seconds since it changed>: Claude's session file for the process.
status() {
  python3 -c 'import json, sys, time; json.dump({"pid": int(sys.argv[1]), "cwd": sys.argv[2], "status": sys.argv[3], "statusUpdatedAt": int((time.time() - int(sys.argv[4])) * 1000)}, open(sys.argv[5], "w"))' \
    "$1" "$held" "$2" "$3" "$HOME/.claude/sessions/$1.json"
}
holder() { health alive "$listed" "$item" "$held" "" "$@"; }

echo "sessions: an idle session and the worktree it sits in"
lists "$PERSON_PID" "claude --resume"
status "$PERSON_PID" idle "$LONG_IDLE_SECONDS"
check "SessionIdlePastTheGivenSeconds_DoesNotHoldTheWorktree: nobody works there, so nothing is named" \
  '[ -z "$(holder "$IDLE_AFTER_SECONDS")" ]'
check "SessionIdleWithNoIdleSecondsGiven_HoldsTheWorktree: the health job gives none and counts every session" \
  '[ "$(holder)" = "process $PERSON_PID" ]'
status "$PERSON_PID" idle "$SHORT_IDLE_SECONDS"
check "SessionIdleForLessThanTheGivenSeconds_HoldsTheWorktree: its person may be reading the last answer" \
  '[ "$(holder "$IDLE_AFTER_SECONDS")" = "process $PERSON_PID" ]'
status "$PERSON_PID" shell "$LONG_IDLE_SECONDS"
check "SessionRunningAShellCommand_HoldsTheWorktree: a long command is work, however long ago it started" \
  '[ "$(holder "$IDLE_AFTER_SECONDS")" = "process $PERSON_PID" ]'
rm -f "$HOME/.claude/sessions/$PERSON_PID.json"
check "SessionWithNoStatus_HoldsTheWorktree: nothing says it is idle" \
  '[ "$(holder "$IDLE_AFTER_SECONDS")" = "process $PERSON_PID" ]'
lists "$AGENT_PID" "claude -p /flow:implement $item"
status "$AGENT_PID" idle "$LONG_IDLE_SECONDS"
check "UnattendedAgentIdlePastTheGivenSeconds_HoldsTheWorktree: only a session a person started is passed over" \
  '[ "$(holder "$IDLE_AFTER_SECONDS")" = "process $AGENT_PID" ]'
lists "$PERSON_PID" "claude --resume" "$SECOND_PID" "claude --resume"
status "$PERSON_PID" idle "$LONG_IDLE_SECONDS"; status "$SECOND_PID" busy "$LONG_IDLE_SECONDS"
check "BusySessionBesideAnIdleOne_IsTheOneNamed: the idle one is passed over and the working one holds the worktree" \
  '[ "$(holder "$IDLE_AFTER_SECONDS")" = "process $SECOND_PID" ]'

echo "sessions: the status Claude writes"
lists "$PERSON_PID" "claude --resume"
status "$PERSON_PID" shell "$LONG_IDLE_SECONDS"
check "StatusShell_ReadsAsBusy: a session running a shell command is working" \
  '[ "$(health session "$listed" "$PERSON_PID")" = "claude process $PERSON_PID, busy" ]'
status "$PERSON_PID" waiting "$LONG_IDLE_SECONDS"
check "StatusWaiting_ReadsAsIdle: a session waiting on its user does no work" \
  'health session "$listed" "$PERSON_PID" | grep -q "^claude process $PERSON_PID, idle "'

if [ "$fails" -eq 0 ]; then echo "sessions: ok"; else echo "sessions: $fails failed"; exit 1; fi
