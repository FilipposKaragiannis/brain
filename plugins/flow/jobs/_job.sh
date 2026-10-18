#!/bin/sh
# Shared by the job scripts: host argument, a lock so overlapping schedules skip instead of
# colliding, a log under <flow home>/log/<job>.log, and the host runner. A job sources this
# after setting $job, then calls job_start "$host"; everything it prints goes to the log too.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/host.sh"
job_log_dir() { printf '%s/log' "$(flow_home)"; }
job_say() { job_last="$*"; printf '%s\t%s\t%s\n' "$(now_iso)" "$job" "$*" | tee -a "$(job_log_dir)/$job.log"; }
die() { job_last="error: $1"; echo "flow: $1" >&2; exit "${2:-1}"; }
# job_base: the job a worker belongs to (next-2 is next). Pause and the schedule are per job.
job_base() { printf '%s' "${job%-[0-9]*}"; }
# job_record <exit>: one line per run in <flow home>/log/runs.jsonl, read by scripts/jobs.sh:
# the job, its start, its length in seconds, the exit code and the last thing it said. A run that
# a pause or a live lock skips is a line too, so every scheduled start shows. Kept to the last
# 4000 lines.
job_record() {
  _runs="$(job_log_dir)/runs.jsonl"; _end="$(date +%s)"
  { json_obj job="$job" at="${job_at:-$(now_iso)}" seconds="$((_end - ${job_t0:-$_end}))" exit="$1" result="${job_last:-}"; echo; } >> "$_runs"
  if [ "$(wc -l < "$_runs")" -gt 5000 ]; then tail -n 4000 "$_runs" > "$_runs.$$" && mv "$_runs.$$" "$_runs"; fi
}
job_clock() { mkdir -p "$(job_log_dir)"; job_t0="$(date +%s)"; job_at="$(now_iso)"; }
# job_skip_if_paused: a paused job (scripts/jobs.sh pause) exits at once, quietly, until resumed.
job_skip_if_paused() {
  [ -f "$(job_log_dir)/$(job_base).paused" ] || return 0
  job_clock; job_say "paused: resume it with the flow jobs skill"; job_record 0; exit 0
}
# job_lock: exit 0 quietly when another run of this job is alive; a lock whose pid is gone is stale.
job_lock() {
  d="$(job_log_dir)/$job.lock"
  if mkdir "$d" 2>/dev/null; then :; else
    pid="$(cat "$d/pid" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then job_say "skipped: run $pid still going"; job_record 0; exit 0; fi
    rm -rf "$d"; mkdir "$d" || die "cannot lock $d"
  fi
  echo $$ > "$d/pid"; printf '%s' "$job_at" > "$d/at"
  trap 'job_end $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
job_end() { rm -rf "$d"; job_record "$1"; }
job_start() {
  host="$1"
  host_check "$host" || exit 2
  job_clock
  job_skip_if_paused
  job_lock
  job_say "start on $host in $(flow_home)"
}
# job_model / job_effort: the orchestrating session's model from jobs.model / jobs.effort, if set.
job_model() { cfg jobs.model; }
job_effort() { cfg jobs.effort; }
