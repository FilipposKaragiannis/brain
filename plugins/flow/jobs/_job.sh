#!/bin/sh
# Shared by the job scripts: host argument, a lock so overlapping schedules skip instead of
# colliding, a log under <flow home>/log/<job>.log, and the host runner. A job sources this
# after setting $job, then calls job_start "$host"; everything it prints goes to the log too.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/host.sh"
job_log_dir() { printf '%s/log' "$(flow_home)"; }
job_say() { printf '%s\t%s\t%s\n' "$(now_iso)" "$job" "$*" | tee -a "$(job_log_dir)/$job.log"; }
# job_lock: exit 0 quietly when another run of this job is alive; a lock whose pid is gone is stale.
job_lock() {
  d="$(job_log_dir)/$job.lock"
  if mkdir "$d" 2>/dev/null; then :; else
    pid="$(cat "$d/pid" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then job_say "skipped: run $pid still going"; exit 0; fi
    rm -rf "$d"; mkdir "$d" || die "cannot lock $d"
  fi
  echo $$ > "$d/pid"
  trap 'rm -rf "$d"' EXIT INT TERM
}
job_start() {
  host="$1"
  host_check "$host" || exit 2
  mkdir -p "$(job_log_dir)"
  job_lock
  job_say "start on $host in $(flow_home)"
}
# job_model / job_effort: the orchestrating session's model from jobs.model / jobs.effort, if set.
job_model() { cfg jobs.model; }
job_effort() { cfg jobs.effort; }
