#!/bin/sh
# jobs.sh <command> [name]: run and watch the scheduled jobs on this machine.
#   status [--json]        every schedule: its job and host, schedule, state, last run and its
#                          result, next run, last 7 days, and each worker of next with its host
#   history <name> [N]     the last N runs (default 10): start, length, exit, outcome, last line
#   logs <name> [N]        the last N lines of the schedule's log and of each worker's (default 40)
#   run <name>             start a run now, as the schedule would; a running one is left alone
#   stop <name>            end the running run and every session under it
#   pause <name|all>       later runs exit at once until resume; a running run finishes
#   resume <name|all>
#   install [name|all]     write and load each schedule jobs.schedule names
#   uninstall [name|all]   unload it and remove its schedule file; takes a schedule the config no
#                          longer names too
# The schedules live in .flow/config.yaml: jobs.schedule.<name> is "every 30m [args]", "daily
# 02:00 [args]" or "weekly sun 03:00 [args]". A name is a job (next, comments, intake, retro,
# health), or a job, a dash and a label of a lowercase letter then lowercase letters and digits
# (next-codex, next-gh81), so one job can run on several schedules, each with its own args. Each
# schedule has its own agent, log, lock, pause and history, and the job script learns its name
# from --as <name>. jobs.host picks claude or codex (default claude); args that begin with claude
# or codex run that schedule on that host instead. jobs.<host>.model and jobs.<host>.effort set
# the model and effort of the sessions a job starts. jobs.workers ({claude: 1, codex: 2}) starts
# the plain next schedule's workers on their own hosts instead; a named next schedule takes
# --workers N in its args, or runs one worker. status --json gives each row its name, its job
# (the script), its host, and configured: false for a schedule installed here that the config no
# longer names. run and install refuse a bad jobs.host, effort or jobs.workers (exit 2), naming
# its line in the config, a next schedule whose args set --workers while jobs.workers does too,
# and a bad schedule name.
# On macOS a schedule is a launchd agent, com.<repo>.flow.<name>, loaded at login: it runs while
# you are logged in and the Mac is awake. Elsewhere install prints the crontab lines to add.
set -u
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/host.sh"
. "$FLOW_PLUGIN/lib/workers.sh"
JOBS="next comments intake retro health"
log="$(flow_home)/log"; main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
agents="${FLOW_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
prefix="com.$(basename "$main" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-').flow"
scheduler="${FLOW_SCHEDULER:-$([ "$(uname)" = Darwin ] && echo launchd || echo cron)}"
host="$(cfg_or jobs.host claude)"
domain="gui/$(id -u)"
py() { python3 -I "$FLOW_PLUGIN/scripts/_jobs.py" "$@"; }
spec() { cfg "jobs.schedule.$1"; }
# job_of <name>: the job a schedule runs (next for next-codex).
job_of() { printf '%s' "${1%%-*}"; }
# known <name>: a schedule name, or a refusal saying why not, exit 2.
known() { py name "$1" $JOBS || exit 2; }
# named <name>: known, and a job or a schedule the config names: run, pause and resume take these.
named() { known "$1"; [ "$1" = "$(job_of "$1")" ] || [ -n "$(spec "$1")" ] || die "no schedule $1: set jobs.schedule.$1 in .flow/config.yaml" 2; }
# schedules: every job, then each other schedule the config names, in its order.
schedules() {
  echo $JOBS | tr ' ' '\n'
  for n in $(yaml_keys "$(config_file)" jobs.schedule); do case " $JOBS " in *" $n "*) ;; *) echo "$n" ;; esac; done
}
# orphans: the schedules installed here that the config no longer names, from their agents.
orphans() {
  _all=" $(schedules | tr '\n' ' ') "
  for f in "$agents/$prefix".*.plist; do
    [ -f "$f" ] || continue
    n="${f##*/}"; n="${n#"$prefix".}"; n="${n%.plist}"
    case "$_all" in *" $n "*) continue ;; esac
    py name "$n" $JOBS 2>/dev/null && echo "$n"
  done
}
targets() {
  case "${1:-all}" in
    all) for j in $(schedules); do [ -z "$(spec "$j")" ] || { known "$j"; echo "$j"; }; done ;;
    *) known "$1"; echo "$1" ;;
  esac
}
# host_of <name>: the host the schedule runs on: the host word its args begin with, else jobs.host.
host_of() { _h=""; _s="$(spec "$1")"; [ -z "$_s" ] || _h="$(py host "$_s" 2>/dev/null)"; printf '%s' "${_h:-$host}"; }
# command_for <name>: the schedule's command; its args come back from _jobs.py checked and quoted,
# its host word as the host argument, and a named schedule tells the job its name.
command_for() {
  s="$(spec "$1")"; a=""; [ -n "$s" ] && a=" $(py args "$s")"
  as=""; [ "$1" = "$(job_of "$1")" ] || as=" --as $1"
  printf '.flow/jobs/%s.sh %s%s%s' "$(job_of "$1")" "$(host_of "$1")" "$as" "$a"
}
label() { printf '%s.%s' "$prefix" "$1"; }
plist() { printf '%s/%s.plist' "$agents" "$(label "$1")"; }
loaded() { [ "$scheduler" = launchd ] && launchctl print "$domain/$(label "$1")" >/dev/null 2>&1; }
# is_job <pid> <job>: the pid still runs jobs/<job>.sh; a lock left by a restart can name a pid
# the system has since given to something else.
is_job() { case "$(ps -o command= -p "$1" 2>/dev/null)" in *"jobs/$2.sh"*) return 0 ;; esac; return 1; }
# live <name>: the pids of its running runs, one per worker, from the schedule's locks.
live() {
  for d in "$log/$1.lock" "$log/$1"-[0-9]*.lock; do
    [ -f "$d/pid" ] || continue
    p="$(cat "$d/pid")"; is_job "$p" "$(job_of "$1")" && echo "$p"
  done
  if loaded "$1"; then launchctl print "$domain/$(label "$1")" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p'; fi
}
# settings_ok <name>...: the jobs settings a run would refuse are refused here, before anything
# starts: jobs.host for every schedule, its host's model and effort for the jobs that start
# sessions unless the schedule's args give an --effort, jobs.workers for next, and a next schedule that sets --workers beside it.
settings_ok() {
  _bad="$(host_jobs_host_problem)"
  if [ -z "$_bad" ]; then for _j in "$@"; do case "$(job_of "$_j")" in comments|intake|retro)
    case " $(spec "$_j") " in *" --effort "*) continue ;; esac
    _bad="$(host_jobs_pair_problem "$(host_of "$_j")")"; [ -z "$_bad" ] || break ;; esac; done; fi
  if [ -z "$_bad" ]; then case " $* " in *" next "*)
    if ! _plan="$(jobs_workers 2>&1)"; then _bad="${_plan#flow: }"
    elif [ -n "$_plan" ]; then case " $(spec next) " in *" --workers "*)
      _bad="$(host_cfg_where jobs.workers): jobs.workers and --workers in jobs.schedule.next both set the workers: keep one" ;; esac
    fi ;; esac
  fi
  [ -z "$_bad" ] || { printf 'flow: %s\n' "$_bad" >&2; exit 2; }
}
descendants() { for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

cmd="${1:-status}"; [ $# -gt 0 ] && shift
case "$cmd" in
  status)
    json=""; [ "${1:-}" = --json ] && json=--json
    set --
    for j in $(schedules) $(orphans); do set -- "$@" "$j=$(spec "$j")"; done
    # shellcheck disable=SC2086
    py status "$log" "$agents" "$prefix" $json --host "$host" --jobs "$JOBS" --workers "$(jobs_workers 2>/dev/null | tr '\n' ' ')" "$@" ;;
  history) [ -n "${1:-}" ] || die "history <name> [N]" 2; known "$1"; py history "$log" "$1" "${2:-10}" ;;
  logs)
    [ -n "${1:-}" ] || die "logs <name> [N]" 2; known "$1"
    for f in "$log/$1.log" "$log/$1"-[0-9]*.log; do
      [ -f "$f" ] || continue
      echo "== $(basename "$f")"; tail -n "${2:-40}" "$f"
    done ;;
  run)
    [ -n "${1:-}" ] || die "run <name>" 2; named "$1"; settings_ok "$1"
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
    [ -n "${1:-}" ] || die "stop <name>" 2; known "$1"
    pids="$(for p in $(live "$1" | sort -u); do echo "$p"; descendants "$p"; done | sort -u)"
    [ -n "$pids" ] || { echo "$1 is not running"; exit 0; }
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
    echo "$1 stopped: $(printf '%s\n' $pids | wc -l | tr -d ' ') process(es) ended" ;;
  pause|resume)
    [ -n "${1:-}" ] || die "$cmd <name|all>" 2
    list="$(schedules | tr '\n' ' ')"; list="${list% }"; [ "$1" = all ] || { named "$1"; list="$1"; }
    mkdir -p "$log"
    for j in $list; do
      if [ "$cmd" = pause ]; then : > "$log/$j.paused"; else rm -f "$log/$j.paused"; fi
    done
    if [ "$cmd" = pause ]; then echo "paused: $list. A running run finishes; stop ends it now."
    else echo "resumed: $list"; fi ;;
  install)
    list="$(targets "${1:-all}")" || exit 2
    # shellcheck disable=SC2086
    settings_ok $list
    [ -n "$list" ] || die "no job has a schedule: set jobs.schedule.<name> in .flow/config.yaml" 2
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
    list="$(schedules) $(orphans)"; [ "${1:-all}" = all ] || { known "$1"; list="$1"; }
    for j in $list; do
      [ -f "$(plist "$j")" ] || loaded "$j" || continue
      [ -z "$(live "$j")" ] || { echo "$j: running now; stop it first or wait"; continue; }
      launchctl bootout "$domain/$(label "$j")" 2>/dev/null
      rm -f "$(plist "$j")"
      echo "$j: unscheduled"
    done ;;
  *) die "unknown command $cmd: status, history, logs, run, stop, pause, resume, install, uninstall" 2 ;;
esac
