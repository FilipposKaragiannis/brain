#!/bin/sh
# Health job: check the worktree pool and the gates, with no model spend while all is well.
#   jobs/health.sh <claude|codex> [--dry-run] [--model <name>] [--effort <level>]
# First frees the worktrees whose PR was merged or whose item closed (`steward.sh sweep`, as the
# next job does), so a merge clears its gate within one cycle even while a next run is busy.
# Then runs `steward.sh health`: clears the run records whose process is gone, releases a claim
# that holds nothing, resumes work a dead run cut off (the host runs only then, and only up to
# jobs.health.max_resumes times before an escalation gate), brings clean task branches in step
# with their remote (a push only with jobs.health.push: true) and with their base (a merge once
# past jobs.health.behind_base; a conflict or a diverged branch goes to the sync step of the
# item's next run), reminds on gates pending past jobs.health.gate_reminder, and says once when
# the pool is full and the next job has no worktree to start in. It clears a planned hold
# (state.held_by) that is stale or wrong: the holder unreadable, holding no worktree and no run,
# or its changes no longer sharing a path with the held item's; a hold on itself; the newest hold
# in a cycle. Each clear is an `unheld` line in events.log. A hold whose holder closed stays:
# next.sh releases it with the note to merge the holder's work and check the plan. A valid hold waiting over a day is
# said and notified once. Only the holders no tracker list holds are read. Each fact is a line
# in the log and in events.log. Nothing to do: one quiet line, no notification. Schedule it every 15
# minutes; the lock skips an overlap. --dry-run says what it would do and changes nothing.
# A run a spend limit or an auth error stopped is not resumed: its escalation gate ended it, and
# the next job continues the item once the gate clears.
# --model and --effort set the pair a resumed run's steps with no agent run on, instead of
# jobs.<host>.model and jobs.<host>.effort.
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
swept=0
# shellcheck disable=SC2086
job_sweep $pass && swept=1
out="$("$FLOW_PLUGIN/scripts/steward.sh" health --host "$host" $pass ${job_opt_model:+--model "$job_opt_model"} ${job_opt_effort:+--effort "$job_opt_effort"} 2>&1)" || {
  printf '%s\n' "$out" | sed '$d' | while IFS= read -r line; do job_say "$line"; done
  job_say "error: steward.sh health stopped: $(printf '%s\n' "$out" | tail -1)"; exit 1
}
printf '%s\n' "$out" | sed '$d' | while IFS= read -r line; do job_say "$line"; done
summary="$(printf '%s\n' "$out" | tail -1)"
word=quiet; [ "$swept" -eq 0 ] || word=done
case "$summary" in
  *"nothing to do") job_say "$word: ${summary#health: }" ;;
  *) job_say "done: ${summary#health: }" ;;
esac
