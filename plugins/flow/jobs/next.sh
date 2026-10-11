#!/bin/sh
# Next job: run ready items unattended until a gate, nothing ready, or the step budget.
#   jobs/next.sh <claude|codex> [item] [--max-steps N]
# The unattended loop (templates/run-unattended.sh) does the work; this adds the lock and the
# log, and turns "nothing ready" (exit 5) and "gate" (exit 4) into quiet exits so a scheduler
# does not flag them. Schedule it at the cadence you want new work picked up.
set -u
job=next
. "$(dirname "$0")/_job.sh"
host="${1:-}"; shift || true
job_start "$host"
"$FLOW_PLUGIN/templates/run-unattended.sh" "$host" "$@" >> "$(job_log_dir)/$job.log" 2>&1; code=$?
case "$code" in
  0|6) job_say "done" ;;
  4) job_say "stopped at a gate (see $(flow_home)/gates)" ;;
  5) job_say "quiet: nothing ready" ;;
  7) job_say "quiet: a run is in flight" ;;
  *) job_say "stopped: exit $code"; exit "$code" ;;
esac
