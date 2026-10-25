#!/bin/sh
# Next job: run ready items unattended until a gate, nothing ready, or the step budget.
#   jobs/next.sh <claude|codex> [item] [--max-steps N] [--workers N]
# The unattended loop (templates/run-unattended.sh) does the work; this adds the lock and the
# log, and turns "nothing ready" (exit 5) and "gate" (exit 4) into quiet exits so a scheduler
# does not flag them. Schedule it at the cadence you want new work picked up. With notify.idle
# true in .flow/config.yaml, the first run that finds nothing ready sends one notification; it
# stays quiet until a run does work again, so a schedule does not repeat it every time.
# --workers N starts N loops at once, each on its own ready item and worktree, each with its own
# lock and log (next-1 ... next-N): a worker still busy from the last schedule is skipped, a free
# one starts. The pool caps them: a worker with no worktree left stops quietly.
set -u
job=next
. "$(dirname "$0")/_job.sh"
host="${1:-}"; shift || true
workers=1; worker=""; item=""; pass=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workers) workers="$2"; shift 2 ;;
    --worker) worker="$2"; shift 2 ;;
    --max-steps) pass="$pass --max-steps $2"; shift 2 ;;
    -*) die "unknown option $1" 2 ;;
    *) item="$1"; shift ;;
  esac
done
case "$workers" in ''|*[!0-9]*|0) die "--workers takes a number from 1" 2 ;; esac
# A tracker that keeps a board (the GitHub adapter's sync) is brought in step once per schedule,
# so an item whose last missing field was just set shows as ready before a worker looks.
# Gates the owner answered on the tracker (an /answer comment) clear first, so the item they free
# can be picked in this same schedule. Then the sweep frees the worktrees whose PR the owner
# merged (steward.sh sweep), so the pool has room before a worker claims.
if [ -z "$worker" ]; then
  job_skip_if_paused
  mkdir -p "$(job_log_dir)"
  if flow_lock answers; then
    for a in $(adapters_configured); do
      [ -x "$FLOW_PLUGIN/adapters/$a/answers.sh" ] && { adapter answers "$a" 2>/dev/null | while read -r id; do job_say "$id: gate answered on the tracker"; done; }
    done
    flow_unlock
  fi
  if flow_lock sweep; then
    "$FLOW_PLUGIN/scripts/steward.sh" sweep 2>/dev/null | while read -r line; do job_say "$line"; done
    flow_unlock
  fi
  for a in $(adapters_configured); do
    [ -x "$FLOW_PLUGIN/adapters/$a/sync.sh" ] && { adapter sync "$a" >/dev/null 2>&1 || true; }
  done
fi
if [ "$workers" -gt 1 ] && [ -z "$worker" ]; then
  [ -z "$item" ] || die "--workers runs the queue; drop the item, or run one worker for it" 2
  host_check "$host" || exit 2
  pids=""; k=1
  while [ "$k" -le "$workers" ]; do
    # shellcheck disable=SC2086
    "$0" "$host" --worker "$k" $pass & pids="$pids $!"
    k=$((k + 1))
  done
  rc=0
  for p in $pids; do wait "$p"; c=$?; [ "$c" -ne 0 ] && [ "$rc" -eq 0 ] && rc=$c; done
  exit "$rc"
fi
[ -n "$worker" ] && job="next-$worker"
job_start "$host"
# shellcheck disable=SC2086
"$FLOW_PLUGIN/templates/run-unattended.sh" "$host" $item $pass >> "$(job_log_dir)/$job.log" 2>&1; code=$?
idle="$(job_log_dir)/next.idle"   # shared by the workers: one notice, not one per worker
case "$code" in 0|4|6) rm -f "$idle" ;; esac
case "$code" in
  0) job_say "done" ;;
  6) said="$(tail -n 5 "$(job_log_dir)/$job.log" | grep 'is split and every child is closed' | tail -1)"
     job_say "${said:-done}" ;;
  4) job_say "stopped at a gate (see $(flow_home)/gates)" ;;
  5) job_say "quiet: nothing ready"
     if [ "$(cfg notify.idle)" = "true" ] && (set -C; : > "$idle") 2>/dev/null; then
       "$FLOW_PLUGIN/scripts/notify.sh" --event idle "The $host job found nothing ready. File or unblock items, or answer the gates on the board." >/dev/null 2>&1 || true
     fi ;;
  7) job_say "quiet: a run is in flight" ;;
  3) job_say "quiet: no free worktree (the pool is at pool_max)" ;;
  *) job_say "stopped: exit $code"; exit "$code" ;;
esac
