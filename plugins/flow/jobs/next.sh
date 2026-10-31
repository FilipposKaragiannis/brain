#!/bin/sh
# Next job: run ready items unattended until a gate, nothing ready, or the step budget.
#   jobs/next.sh <claude|codex> [item] [--max-steps N] [--workers N] [--worker N] [--wait]
# The unattended loop (templates/run-unattended.sh) does the work; this adds the lock and the
# log, and turns "nothing ready" (exit 5) and "gate" (exit 4) into quiet exits so a scheduler
# does not flag them. Schedule it at the cadence you want new work picked up. With notify.idle
# true in .flow/config.yaml, the first run that finds nothing ready sends one notification; it
# stays quiet until a run does work again, so a schedule does not repeat it every time.
# --workers N starts N loops at once, each on its own ready item and worktree, each with its own
# lock and log (next-1 ... next-N): a worker still busy from the last schedule is skipped, a free
# one starts. The pool caps them: a worker with no worktree left stops quietly. The job starts
# the workers in their own session and ends, so one long worker never holds the next schedule
# (launchd starts no run while the last is alive). The launchd agent abandons what its run
# leaves behind (AbandonProcessGroup), or launchd would end every worker when the job exits.
# --wait stays until every worker ends and exits with the first failure.
# jobs.workers in .flow/config.yaml ({claude: 1, codex: 2}) splits the workers across hosts: a
# run of the queue with no --workers starts each worker on its own host, numbered in the map's
# order across hosts, claude first (next-1 on claude, next-2 and next-3 on codex), and the host
# argument only names the run. --workers N on the command line starts N on the host argument.
# --worker N is one worker, as the job starts it; N is a number, so status and pause know it.
set -u
job=next
. "$(dirname "$0")/_job.sh"
. "$FLOW_PLUGIN/lib/workers.sh"
host="${1:-}"; shift || true
workers=1; workers_given=0; worker=""; item=""; pass=""; wait_all=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workers) workers="$2"; workers_given=1; shift 2 ;;
    --worker) worker="$2"; shift 2 ;;
    --max-steps) pass="$pass --max-steps $2"; shift 2 ;;
    --wait) wait_all=1; shift ;;
    -*) die "unknown option $1" 2 ;;
    *) item="$1"; shift ;;
  esac
done
case "$workers" in ''|*[!0-9]*|0) die "--workers takes a number from 1" 2 ;; esac
case "${worker:-1}" in ''|*[!0-9]*|0) die "--worker takes a number from 1; to split the workers across hosts, set jobs.workers in .flow/config.yaml" 2 ;; esac
# plan: one host:count word per host whose workers this run starts; empty for one run in place.
# A paused run never reads it, and a bad jobs.workers stops the run before the tracker is touched.
# A tracker that keeps a board (the GitHub adapter's sync) is brought in step once per schedule,
# so an item whose last missing field was just set shows as ready before a worker looks.
# Gates the owner answered on the tracker (an /answer comment) clear first, so the item they free
# can be picked in this same schedule. Then the sweep frees the worktrees whose PR the owner
# merged (steward.sh sweep), so the pool has room before a worker claims.
plan=""
if [ -z "$worker" ]; then
  job_skip_if_paused
  if [ -z "$item" ] && [ "$workers_given" -eq 0 ] && ! plan="$(jobs_workers 2>&1)"; then
    printf '%s\n' "$plan" >&2; job_clock; job_say "error: ${plan#flow: }" >/dev/null; job_record 2; exit 2
  fi
  if [ -z "$plan" ] && [ "$workers" -gt 1 ]; then plan="$host:$workers"; fi
  mkdir -p "$(job_log_dir)"
  if flow_lock answers; then
    for a in $(adapters_configured); do
      [ -x "$FLOW_PLUGIN/adapters/$a/answers.sh" ] && { adapter answers "$a" 2>/dev/null | while read -r id; do job_say "$id: gate answered on the tracker"; done; }
    done
    flow_unlock
  fi
  job_sweep || true
  for a in $(adapters_configured); do
    [ -x "$FLOW_PLUGIN/adapters/$a/sync.sh" ] && { adapter sync "$a" >/dev/null 2>&1 || true; }
  done
fi
if [ -n "$plan" ]; then
  [ -z "$item" ] || die "--workers runs the queue; drop the item, or run one worker for it" 2
  for hn in $plan; do host_check "${hn%:*}" || exit 2; done
  [ -x "$0" ] || die "$0 is not executable, so no worker can start" 2
  # detached <log> <command...>: runs the command in its own session, outside the scheduler's
  # process group; a command that cannot start is a line in <log>, as the worker would write it.
  detached() { exec python3 -I -c 'import os, sys, time
try: os.setsid()
except OSError: pass
try: os.execv(sys.argv[2], sys.argv[2:])
except OSError as e:
    with open(sys.argv[1], "a") as log: log.write("%s\tnext-%s\tstopped: cannot start: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), sys.argv[5], e))
    sys.exit(1)' "$@" </dev/null; }
  pids=""; k=1
  for hn in $plan; do
    i=1
    while [ "$i" -le "${hn#*:}" ]; do
      # shellcheck disable=SC2086
      if [ "$wait_all" -eq 1 ]; then "$0" "${hn%:*}" --worker "$k" $pass </dev/null &
      else detached "$(job_log_dir)/next-$k.log" "$0" "${hn%:*}" --worker "$k" $pass &
      fi
      pids="$pids $!"
      k=$((k + 1)); i=$((i + 1))
    done
  done
  [ "$wait_all" -eq 1 ] || exit 0
  rc=0
  for p in $pids; do wait "$p"; c=$?; [ "$c" -ne 0 ] && [ "$rc" -eq 0 ] && rc=$c; done
  exit "$rc"
fi
[ -n "$worker" ] && job="next-$worker"
job_start "$host"
n0="$(wc -l < "$(job_log_dir)/$job.log" 2>/dev/null | tr -d ' ')"; n0="${n0:-0}"
# shellcheck disable=SC2086
"$FLOW_PLUGIN/templates/run-unattended.sh" "$host" $item $pass >> "$(job_log_dir)/$job.log" 2>&1; code=$?
# The steps this run made, from its own lines of the log (the step line is not anchored: a host
# whose last output has no newline glues it), so the last word carries the count and a run that
# ended as if done without one step says so (health counts those).
steps="$(tail -n +"$((n0 + 1))" "$(job_log_dir)/$job.log" | grep -c 'run-unattended: [^ ]* step [^ ]* in /')"
ran() { case "$steps" in 0) ;; 1) echo ", 1 step" ;; *) echo ", $steps steps" ;; esac; }
idle="$(job_log_dir)/next.idle"   # shared by the workers: one notice, not one per worker
case "$code" in 0|4|6) rm -f "$idle" ;; esac
if [ "$steps" -eq 0 ] && [ -z "$item" ] && case "$code" in 0|4|6) true ;; *) false ;; esac; then
  why="$(tail -n +"$((n0 + 1))" "$(job_log_dir)/$job.log" | grep -v -e '^run-unattended: next.sh exit ' -e '^run-unattended: stopped (exit ' | tail -n 1)"
  job_say "stopped: no step ran (exit $code: ${why:-no reason in the log})"
  exit 0
fi
case "$code" in
  0) job_say "done$(ran)" ;;
  6) # the reason is the line next.sh wrote just before the loop reported its exit
     said="$(grep -B1 'run-unattended: next.sh exit 6$' "$(job_log_dir)/$job.log" | tail -n 2 | head -n 1 | grep -e 'is split and every child is closed' -e 'is done (every step ran)' -e 'is closed$')"
     job_say "${said:-done}$(ran)" ;;
  4) job_say "stopped at a gate (see $(flow_home)/gates)$(ran)" ;;
  5) job_say "quiet: nothing ready"
     if [ "$(cfg notify.idle)" = "true" ] && (set -C; : > "$idle") 2>/dev/null; then
       "$FLOW_PLUGIN/scripts/notify.sh" --event idle "The $host job found nothing ready. File or unblock items, or answer the gates on the board." >/dev/null 2>&1 || true
     fi ;;
  7) # the reason is the line next.sh wrote just before the loop reported its exit, as for 6
     if grep -B1 'run-unattended: next.sh exit 7$' "$(job_log_dir)/$job.log" | tail -n 2 | head -n 1 | grep -q 'another run is picking an item'; then job_say "quiet: another worker held the pick for over ${FLOW_LOCK_WAIT:-60}s"
     else job_say "quiet: a run is in flight"; fi ;;
  3) job_say "quiet: no free worktree (the pool is at pool_max)" ;;
  *) job_say "stopped: exit $code"; exit "$code" ;;
esac
