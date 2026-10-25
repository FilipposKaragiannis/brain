#!/bin/sh
# jobs.sh <command> [job]: run and watch the scheduled jobs on this machine.
#   status [--json]       every job: schedule, state, last run and its result, next run, last 7 days
#   history <job> [N]     the last N runs (default 10): start, length, exit, outcome, last line
#   logs <job> [N]        the last N lines of the job's log and of each worker's (default 40)
#   run <job>             start a run now, as the schedule would; a running job is left alone
#   stop <job>            end the running run and every session under it
#   pause <job|all>       later runs exit at once until resume; a running run finishes
#   resume <job|all>
#   install [job|all]     write and load the schedule of each job jobs.schedule names
#   uninstall [job|all]   unload it and remove its schedule file
# The schedule lives in .flow/config.yaml: jobs.schedule.<job> is "every 30m [args]", "daily
# 02:00 [args]" or "weekly sun 03:00 [args]"; jobs.host picks claude or codex (default claude),
# and jobs.<host>.model and jobs.<host>.effort set the model and effort of the sessions it starts.
# run and install refuse a bad jobs.host or effort (exit 2), naming its line in the config.
# On macOS a job is a launchd agent, com.<repo>.flow.<job>, loaded at login: it runs while you
# are logged in and the Mac is awake. Elsewhere install prints the crontab lines to add.
set -u
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/host.sh"
JOBS="next comments intake retro health"
log="$(flow_home)/log"; main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
agents="${FLOW_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
prefix="com.$(basename "$main" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-').flow"
scheduler="${FLOW_SCHEDULER:-$([ "$(uname)" = Darwin ] && echo launchd || echo cron)}"
host="$(cfg_or jobs.host claude)"
domain="gui/$(id -u)"
py() { python3 -I "$FLOW_PLUGIN/scripts/_jobs.py" "$@"; }
spec() { cfg "jobs.schedule.$1"; }
known() { case " $JOBS " in *" $1 "*) return 0 ;; esac; die "no job $1: one of $JOBS" 2; }
targets() {
  case "${1:-all}" in
    all) for j in $JOBS; do [ -n "$(spec "$j")" ] && echo "$j"; done ;;
    *) known "$1"; echo "$1" ;;
  esac
}
# command_for <job>: the job's command; its args come back from _jobs.py checked and quoted.
command_for() {
  s="$(spec "$1")"; a=""; [ -n "$s" ] && a=" $(py args "$s")"
  printf '.flow/jobs/%s.sh %s%s' "$1" "$host" "$a"
}
label() { printf '%s.%s' "$prefix" "$1"; }
plist() { printf '%s/%s.plist' "$agents" "$(label "$1")"; }
loaded() { [ "$scheduler" = launchd ] && launchctl print "$domain/$(label "$1")" >/dev/null 2>&1; }
# is_job <pid> <job>: the pid still runs jobs/<job>.sh; a lock left by a restart can name a pid
# the system has since given to something else.
is_job() { case "$(ps -o command= -p "$1" 2>/dev/null)" in *"jobs/$2.sh"*) return 0 ;; esac; return 1; }
# live <job>: the pids of its running runs, one per worker, from the job locks.
live() {
  for d in "$log/$1.lock" "$log/$1"-[0-9]*.lock; do
    [ -f "$d/pid" ] || continue
    p="$(cat "$d/pid")"; is_job "$p" "$1" && echo "$p"
  done
  if loaded "$1"; then launchctl print "$domain/$(label "$1")" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p'; fi
}
# settings_ok: the jobs settings a run would refuse are refused here, before anything starts.
settings_ok() { _bad="$(host_jobs_problems)"; [ -z "$_bad" ] || { printf '%s\n' "$_bad" | sed 's/^/flow: /' >&2; exit 2; }; }
descendants() { for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

cmd="${1:-status}"; [ $# -gt 0 ] && shift
case "$cmd" in
  status)
    json=""; [ "${1:-}" = --json ] && json=--json
    set --
    for j in $JOBS; do set -- "$@" "$j=$(spec "$j")"; done
    # shellcheck disable=SC2086
    py status "$log" "$agents" "$prefix" $json "$@" ;;
  history) [ -n "${1:-}" ] || die "history <job> [N]" 2; known "$1"; py history "$log" "$1" "${2:-10}" ;;
  logs)
    [ -n "${1:-}" ] || die "logs <job> [N]" 2; known "$1"
    for f in "$log/$1.log" "$log/$1"-[0-9]*.log; do
      [ -f "$f" ] || continue
      echo "== $(basename "$f")"; tail -n "${2:-40}" "$f"
    done ;;
  run)
    [ -n "${1:-}" ] || die "run <job>" 2; known "$1"; settings_ok
    [ -z "$(spec "$1")" ] || py args "$(spec "$1")" >/dev/null || exit 2
    [ -z "$(live "$1")" ] || { echo "$1 is running already: jobs.sh stop $1 ends it"; exit 0; }
    if loaded "$1"; then
      launchctl kickstart "$domain/$(label "$1")" || die "launchd could not start $(label "$1")"
      echo "$1 started through launchd"
    else
      mkdir -p "$log"
      (cd "$main" && nohup sh -c "$(command_for "$1")" >> "$log/launchd-$1.log" 2>&1 &)
      echo "$1 started: $(command_for "$1")"
    fi ;;
  stop)
    [ -n "${1:-}" ] || die "stop <job>" 2; known "$1"
    pids="$(for p in $(live "$1" | sort -u); do echo "$p"; descendants "$p"; done | sort -u)"
    [ -n "$pids" ] || { echo "$1 is not running"; exit 0; }
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
    echo "$1 stopped: $(printf '%s\n' $pids | wc -l | tr -d ' ') process(es) ended" ;;
  pause|resume)
    [ -n "${1:-}" ] || die "$cmd <job|all>" 2
    list="$JOBS"; [ "$1" = all ] || { known "$1"; list="$1"; }
    mkdir -p "$log"
    for j in $list; do
      if [ "$cmd" = pause ]; then : > "$log/$j.paused"; else rm -f "$log/$j.paused"; fi
    done
    if [ "$cmd" = pause ]; then echo "paused: $list. A running run finishes; stop ends it now."
    else echo "resumed: $list"; fi ;;
  install)
    settings_ok; list="$(targets "${1:-all}")"
    [ -n "$list" ] || die "no job has a schedule: set jobs.schedule.<job> in .flow/config.yaml" 2
    mkdir -p "$log"
    for j in $list; do
      s="$(spec "$j")"; [ -n "$s" ] || die "set jobs.schedule.$j in .flow/config.yaml first" 2
      py args "$s" >/dev/null || exit 2
      if [ "$scheduler" != launchd ]; then
        py cron "$s" "$main" "$(command_for "$j")" "$log/launchd-$j.log" || exit 2; continue
      fi
      if loaded "$j"; then
        [ -z "$(live "$j")" ] || { echo "$j: running now, left as it is; install it again after the run"; continue; }
        launchctl bootout "$domain/$(label "$j")" 2>/dev/null
      fi
      mkdir -p "$agents"
      py plist "$(label "$j")" "$main" "$(command_for "$j")" "$s" "$log/launchd-$j.log" "$PATH" > "$(plist "$j")" || exit 1
      launchctl enable "$domain/$(label "$j")" 2>/dev/null
      launchctl bootstrap "$domain" "$(plist "$j")" || die "launchd refused $(plist "$j")"
      echo "$j: $s, as $(label "$j")"
    done
    [ "$scheduler" = launchd ] || echo "(add these lines with crontab -e; flow does not edit your crontab)" ;;
  uninstall)
    [ "$scheduler" = launchd ] || die "remove the lines from your crontab with crontab -e" 2
    list="$JOBS"; [ "${1:-all}" = all ] || { known "$1"; list="$1"; }
    for j in $list; do
      [ -f "$(plist "$j")" ] || loaded "$j" || continue
      [ -z "$(live "$j")" ] || { echo "$j: running now; stop it first or wait"; continue; }
      launchctl bootout "$domain/$(label "$j")" 2>/dev/null
      rm -f "$(plist "$j")"
      echo "$j: unscheduled"
    done ;;
  *) die "unknown command $cmd: status, history, logs, run, stop, pause, resume, install, uninstall" 2 ;;
esac
