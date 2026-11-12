#!/bin/sh
# verify.sh <item> [--base <ref>]: the one verify run. From the claimed worktree, runs in order
# build, format (changed files only), tests, mutation (signal, never a fail) and the project
# gates from .flow/config.yaml, each once, and writes
# <reports>/verify.json {status, checks: [{name, status, command, summary}], attempts, base,
# head, changed_files, feel_test} and its Markdown twin verify.md for the PR body. Commands come
# from .standards/config.json (build, test, mutation, languages[].format). An empty mutation is
# the off switch (a skipped check); a mutation command with {files} runs on the changed source
# files only, like a format command, and is skipped when none changed. A project gate is
# `name: command` (always runs) or a map with `command:` and `paths:` (runs when a changed file
# matches a glob; otherwise a skipped check). feel_test is true when a changed file matches
# feel_test_paths in the flow config. Never edits anything. The report is built from data by
# scripts/_verify_report.py and renamed into place, so it is never empty or half written; when it
# cannot be built, verify says why on stderr, writes a minimal report with status fail and the
# cause as a check summary, and exits 1. The changed files are those since the base: --base, else
# the base the claim recorded (.flow/claim.json in the worktree) when it is a valid base name,
# else the config base. Exit 0 on pass, 1 on fail.
#
# verify.sh <item> --start [--base <ref>]: the same run, detached from the caller (its own session,
# stdin from /dev/null, output to <reports>/verify.out), so it outlives a shell call the host cuts
# short. Returns at once, exit 0. It records the run in <reports>/verify.run (lib/verify.sh) and
# first removes the earlier verify.json and verify.md, so no report of an earlier run reads as this
# one's. A run of the item still going is not started again: --start says so and exits 0. The run
# lasts at most verify.limit from the flow config (s, m, h or d; default 2h): past it, its whole
# process group is stopped and the report is a fail naming the check that was running and the
# limit. A run stopped by a signal, or ended with no report, also leaves a fail report that says so.
# verify.sh <item> --wait [seconds]: waits up to the seconds (default 540) for the started run.
# Exit 0 when it passed and 1 when it failed, printing what the run printed, as the plain run
# does; 3 while it still runs, printing how long it has run and the check it is on. A run that
# died with no report (killed, crashed) is a fail: --wait writes the minimal fail report and exits
# 1. No run started: exit 2. A wait is no rerun: the checks run once, in the started run.
# --detached is --start's own run, never called by hand.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
. "$FLOW_PLUGIN/lib/verify.sh"
usage="usage: verify.sh <item> [--base <ref>] [--start | --wait [seconds]]"
[ $# -ge 1 ] || die "$usage" 2
item="$1"; shift
base=""; mode=run; wait_for=540
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --start) mode=start; shift ;;
    --wait) mode=wait; shift; case "${1:-}" in ''|-*) ;; *) wait_for="$1"; shift ;; esac ;;
    --detached) mode=detached; shift ;;
    *) die "unknown option $1" 2 ;;
  esac
done
case "$wait_for" in ''|*[!0-9]*) die "--wait takes a number of seconds, not $wait_for" 2 ;; esac
given_base="$base"
root="$(repo_root)" || die "not in a git repository"
cd "$root" || exit 1
[ -n "$base" ] || base="$(recorded_base "$root")"
reports="$(reports_dir "$item" "$root")"; mkdir -p "$reports"
log="$reports/verify.log"; run_out="$reports/verify.out"

# next_attempt: the attempt this run is, one past the item's recorded attempts.
next_attempt() {
  na_data="$(adapter read "$item" 2>/dev/null)" || na_data='{}'
  na_attempts="$(state_get "$na_data" attempts)"; printf '%s' $(( ${na_attempts:-0} + 1 ))
}
# report_text <text>: the text as one line of printable characters with no quote or backslash,
# cut to 400, safe inside the JSON string of a minimal report.
report_text() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | LC_ALL=C tr -d '"\\' | cut -c1-400; }
# fail_report <check name> <summary> <sentence>: the minimal report with status fail and one failed
# check, written without the builder and renamed in, with its verify.md twin saying the sentence.
# Name, summary and sentence are report_text already; $attempts, $base and $head_sha are set.
fail_report() {
  safe() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._/-'; }
  printf '{"status": "fail", "checks": [{"name": "%s", "status": "fail", "command": "", "summary": "%s"}], "attempts": %d, "base": "%s", "head": "%s", "changed_files": [], "feel_test": false}\n' \
    "$1" "$2" "$attempts" "$(safe "$base")" "$(safe "$head_sha")" > "$reports/.verify.json.$$.tmp" && mv -f "$reports/.verify.json.$$.tmp" "$reports/verify.json"
  printf '## Verify: fail (attempt %d)\n\n%s\n\nLog: `%s`.\n' "$attempts" "$3" "$log" \
    > "$reports/.verify.md.$$.tmp" && mv -f "$reports/.verify.md.$$.tmp" "$reports/verify.md"
}
# duration <seconds>: 45s, 12m 30s or 2h 05m.
duration() {
  if [ "$1" -lt 60 ]; then printf '%ds' "$1"
  elif [ "$1" -lt 3600 ]; then printf '%dm %02ds' $(($1 / 60)) $(($1 % 60))
  else printf '%dh %02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); fi
}
# limit_seconds: verify.limit from the flow config in seconds; a value that is no duration says so
# on stderr and returns 1.
limit_seconds() { python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds verify.limit "$(cfg_or verify.limit 2h)"; }
# running_now: the check the run is on, as the log names it, or starting before the first.
running_now() { rn_check="$(verify_running_check "$log")"; printf '%s' "${rn_check:-starting}"; }
# unfinished_report <cause>: the fail report of a run that ended with none, naming the check the
# log shows running and the cause, said on stdout and in the log. Exits 1.
unfinished_report() {
  ur_running="$(verify_running_check "$log")"; ur_check="${ur_running%%: *}"; ur_command="${ur_running#*: }"
  if [ -n "$ur_running" ]; then ur_summary="$(report_text "$1 while $ur_check ran ($ur_command)")"
  else ur_check=verify; ur_summary="$(report_text "$1 before the first check")"; fi
  fail_report "$(report_text "$ur_check")" "$ur_summary" "Verify did not finish: $ur_summary."
  printf '\nverify: %s\n' "$ur_summary" >> "$log"
  echo "verify: fail (attempt $attempts): $ur_summary; report $reports/verify.json"
  exit 1
}

# start_run: --start. Under the item's verify lock, so two starts never run the checks twice.
start_run() {
  flow_lock "verify-$(item_slug "$item")" || die "another verify start of $item holds its lock" 1
  if live="$(verify_run_live "$reports" "$item")"; then
    sr_started="$(verify_run_field "$reports" started)"
    echo "verify: a run of $item is already going (pid $live, $(duration $(( $(date +%s) - ${sr_started:-$(date +%s)} ))) in, now: $(running_now)); wait for it with verify.sh $item --wait"
    exit 0
  fi
  limit="$(limit_seconds)" || exit 2
  rm -f "$(verify_run_file "$reports")" "$reports/verify.json" "$reports/verify.md"
  : > "$log"; : > "$run_out"
  started="$(date +%s)"; head_sha="$(git rev-parse --short HEAD)"
  pid="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" spawn "$run_out" sh "$FLOW_PLUGIN/scripts/verify.sh" "$item" --detached ${given_base:+--base "$given_base"})" &&
    [ -n "$pid" ] || die "could not start the verify run of $item"
  printf 'pid %s\nstarted %s\nhead %s\nlimit %s\n' "$pid" "$started" "$head_sha" "$limit" > "$reports/.verify.run.$$.tmp" &&
    mv -f "$reports/.verify.run.$$.tmp" "$(verify_run_file "$reports")" || die "could not record the verify run of $item (pid $pid)"
  echo "verify: started the run of $item (pid $pid, limit $(duration "$limit")); wait for it with verify.sh $item --wait"
  exit 0
}

# wait_run: --wait.
wait_run() {
  [ -f "$(verify_run_file "$reports")" ] || die "no verify run of $item to wait for: start one with verify.sh $item --start" 2
  deadline=$(( $(date +%s) + wait_for ))
  while verify_run_live "$reports" "$item" >/dev/null; do
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      wr_started="$(verify_run_field "$reports" started)"; wr_limit="$(verify_run_field "$reports" limit)"
      echo "verify: still running after $(duration $((now - ${wr_started:-$now}))) of its $(duration "${wr_limit:-0}") limit, now: $(running_now); wait again with verify.sh $item --wait"
      exit 3
    fi
    sleep 1
  done
  cat "$run_out" 2>/dev/null
  if [ ! -f "$reports/verify.json" ]; then
    attempts="$(next_attempt)"; head_sha="$(verify_run_field "$reports" head)"
    unfinished_report "the verify run (pid $(verify_run_field "$reports" pid)) ended with no report, killed or crashed,"
  fi
  [ "$(json_get "$(cat "$reports/verify.json")" status)" = pass ]
  exit
}

# others_in_group: $group_others, the processes of this run's group but this one. pgrep never
# lists itself, and a lone command substitution runs it with no shell of its own in between.
others_in_group() {
  group_others=""
  for og_pid in $(pgrep -g "$$"); do [ "$og_pid" = "$$" ] || group_others="$group_others $og_pid"; done
}
# stop_group: TERM to the rest of this run's group, then KILL to what is left after the grace.
stop_group() {
  others_in_group
  # shellcheck disable=SC2086
  [ -z "$group_others" ] || kill -s TERM $group_others 2>/dev/null
  sg_waited=0
  while others_in_group && [ -n "$group_others" ] && [ "$sg_waited" -lt "$VERIFY_STOP_GRACE" ]; do sleep 1; sg_waited=$((sg_waited + 1)); done
  others_in_group
  # shellcheck disable=SC2086
  [ -z "$group_others" ] || kill -s KILL $group_others 2>/dev/null
}

# run_detached: --detached, the run --start starts as the leader of its own process group. Runs
# the plain run as its child and ends it at the limit or on a signal.
run_detached() {
  [ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$$" ] || die "--detached is the run --start starts; use verify.sh $item --start" 2
  limit="$(limit_seconds)" || exit 2
  started="$(date +%s)"; stop_cause=""
  trap 'stop_cause="${stop_cause:-signal}"' TERM INT HUP
  sh "$FLOW_PLUGIN/scripts/verify.sh" "$item" ${given_base:+--base "$given_base"} &
  child=$!
  while process_running "$child"; do
    [ -z "$stop_cause" ] || break
    [ $(( $(date +%s) - started )) -lt "$limit" ] || { stop_cause=limit; break; }
    sleep 1
  done
  [ -z "$stop_cause" ] || stop_group
  wait "$child"; code=$?
  [ ! -f "$reports/verify.json" ] || exit "$code"
  attempts="$(next_attempt)"; head_sha="$(git rev-parse --short HEAD)"
  case "$stop_cause" in
    limit) unfinished_report "stopped at the verify limit of $(duration "$limit") (verify.limit)" ;;
    signal) unfinished_report "stopped by a signal" ;;
    *) unfinished_report "the run ended (exit $code) with no report" ;;
  esac
}

case "$mode" in
  start) start_run ;;
  wait) wait_run ;;
  detached) run_detached ;;
esac

ref="$base"; git show-ref --verify --quiet "refs/remotes/origin/$base" && ref="origin/$base"
merge_base="$(git merge-base "$ref" HEAD 2>/dev/null || echo "$ref")"
changed="$(git diff --name-only "$merge_base" HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
changed="$(printf '%s\n' "$changed" | grep -v '^$' | grep -v '^\.flow/' | sort -u)"
std=""; [ -f .standards/config.json ] && std="$(cat .standards/config.json)"
: > "$log"
attempts="$(next_attempt)"
overall="pass"
records="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
changed_list="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
# dash runs no EXIT trap on a signal, so INT and TERM clean up too, then die of the same signal
# so a parent shell sees it (an exit 130 would hide it).
trap 'rm -f "$records" "$changed_list"' EXIT
trap 'trap - INT EXIT; rm -f "$records" "$changed_list"; kill -INT $$' INT
trap 'trap - TERM EXIT; rm -f "$records" "$changed_list"; kill -TERM $$' TERM

record() {
  # record <name> <status> <command> <summary source>: one check, four NUL-terminated fields. The
  # report builder turns the source into the summary; nothing here is JSON.
  printf '%s\000%s\000%s\000%s\000' "$1" "$2" "$3" "$4" >> "$records"
}
skipped() {
  # skipped <name> <why>: a check that did not apply, kept in the report so the reader sees why.
  record "$1" skipped "" "$2"
}
changed_matches() {
  # changed_matches <globs, one per line>: true when a changed file matches one of them.
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && glob_match "$g" "$f" && return 0
    done <<EOF_FILES
$changed
EOF_FILES
  done <<EOF_GLOBS
$1
EOF_GLOBS
  return 1
}

run_check() {
  # run_check <name> <command> <kind: gate|signal> [files]
  name="$1"; command="$2"; kind="$3"; files="${4:-}"
  cmd="$(printf '%s' "$command" | sed "s|{files}|$files|g")"
  printf '\n== %s: %s\n' "$name" "$cmd" >> "$log"
  if out="$(sh -c "$cmd" 2>&1)"; then st="pass"; summary="ok"
  else
    st="fail"; [ "$kind" = "signal" ] && st="signal"
    summary="$out"
  fi
  printf '%s\n' "$out" >> "$log"
  [ "$st" = "fail" ] && overall="fail"
  record "$name" "$st" "$cmd" "$summary"
}

build="$(json_get "$std" build)"
if [ -n "$build" ]; then run_check build "$build" gate; else skipped build "no build command in .standards/config.json"; fi
nlang="$(json_length "$std" languages)"; i=0; ran_format=0; all_files=""
while [ "$i" -lt "${nlang:-0}" ]; do
  lang="$(json_get "$std" "languages.$i")"
  exts="$(json_list "$lang" extensions | tr '\n' '|' | sed 's/|$//; s/\./\\./g')"
  nf="$(json_length "$lang" format)"; j=0
  while [ "$j" -lt "${nf:-0}" ]; do
    prefix="$(json_get "$lang" "format.$j.prefix")"; command="$(json_get "$lang" "format.$j.command")"
    files="$(printf '%s\n' "$changed" | grep -E "($exts)$" | { [ -n "$prefix" ] && grep "^$prefix" || cat; } | while read -r f; do [ -f "$f" ] && printf '%s ' "$f"; done)"
    if [ -n "$files" ]; then run_check "format${prefix:+ $prefix}" "$command" gate "$files"; ran_format=1; all_files="$all_files$files"; fi
    j=$((j + 1))
  done
  i=$((i + 1))
done
[ "$ran_format" -eq 1 ] || skipped format "no changed source files under a format rule"
test_cmd="$(json_get "$std" test)"
if [ -n "$test_cmd" ]; then run_check tests "$test_cmd" gate; else skipped tests "no test command in .standards/config.json"; fi
mutation="$(json_get "$std" mutation)"
if [ -z "$mutation" ]; then skipped mutation "mutation is empty in .standards/config.json (off)"
else
  case "$mutation" in
    *'{files}'*) if [ -n "$all_files" ]; then run_check mutation "$mutation" signal "$all_files"; else skipped mutation "no changed source files for the mutation run"; fi ;;
    *) run_check mutation "$mutation" signal ;;
  esac
fi
for name in $(yaml_keys "$(config_file)" gates); do
  command="$(cfg "gates.$name")"; paths=""
  if [ -z "$command" ]; then command="$(cfg "gates.$name.command")"; paths="$(cfg "gates.$name.paths")"; fi
  [ -n "$command" ] || continue
  if [ -n "$paths" ] && ! changed_matches "$paths"; then skipped "gate $name" "no changed file under its paths"; continue; fi
  run_check "gate $name" "$command" gate
done
feel=false
for g in $(cfg feel_test_paths); do
  printf '%s\n' "$changed" | while read -r f; do glob_match "$g" "$f" && exit 3; done
  [ $? -eq 3 ] && { feel=true; break; }
done
printf '%s\n' "$changed" > "$changed_list"
head_sha="$(git rev-parse --short HEAD)"

report_failed() {
  # report_failed <cause>: the report builder failed. Say so, and leave a minimal report that
  # still parses, with status fail and the cause.
  cause="$(report_text "$1")"
  echo "verify: could not build the report: $cause" >&2
  fail_report report "could not build the report: $cause" "The report could not be built: $cause"
  exit 1
}
err="$(python3 -I "$FLOW_PLUGIN/scripts/_verify_report.py" "$records" "$changed_list" "$reports" "$overall" "$attempts" "$base" "$merge_base" "$head_sha" "$feel" "$log" 2>&1 >/dev/null)" \
  || report_failed "$(printf '%s\n' "${err:-the report builder exited non-zero}" | grep -v '^ ' | tail -1 | tr '\n' ' ')"
echo "verify: $overall (attempt $attempts); report $reports/verify.json"
[ "$overall" = "pass" ]
