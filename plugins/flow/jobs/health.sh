#!/bin/sh
# Health job: check the worktree pool and the gates, with no model spend while all is well.
#   jobs/health.sh <claude|codex> [--dry-run]
# Runs `steward.sh health`: clears the run records whose process is gone, releases a claim that
# holds nothing, resumes work a dead run cut off (the host runs only then, and only up to
# jobs.health.max_resumes times before an escalation gate), brings clean task branches in step
# with their remote (a push only with jobs.health.push: true) and with their base (a merge once
# past jobs.health.behind_base; a conflict or a diverged branch goes to the sync step of the
# item's next run), reminds on gates pending past jobs.health.gate_reminder, and says once when
# the pool is full and the next job has no worktree to start in. Each fact is a line in the log
# and in events.log. Nothing to do: one quiet line, no notification. Schedule it every 15
# minutes; the lock skips an overlap. --dry-run says what it would do and changes nothing.
set -u
job=health
. "$(dirname "$0")/_job.sh"
host="${1:-}"; shift || true
pass=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) pass="--dry-run"; shift ;;
    *) die "unknown option $1" 2 ;;
  esac
done
job_start "$host"
out="$("$FLOW_PLUGIN/scripts/steward.sh" health --host "$host" $pass 2>&1)" || {
  printf '%s\n' "$out" | sed '$d' | while IFS= read -r line; do job_say "$line"; done
  job_say "error: steward.sh health stopped: $(printf '%s\n' "$out" | tail -1)"; exit 1
}
printf '%s\n' "$out" | sed '$d' | while IFS= read -r line; do job_say "$line"; done
summary="$(printf '%s\n' "$out" | tail -1)"
case "$summary" in
  *"nothing to do") job_say "quiet: ${summary#health: }" ;;
  *) job_say "done: ${summary#health: }" ;;
esac
