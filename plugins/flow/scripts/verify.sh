#!/bin/sh
# verify.sh <item> [--base <ref>] [--fresh]: the one verify run. From the claimed worktree, runs in
# order build, format (changed files only), tests, mutation (signal, never a fail) and the project
# gates from .flow/config.yaml, each once, and writes
# <reports>/verify.json {status, verdict, checks: [{name, status, command, summary, seconds}],
# attempts, base, head, changed_files, feel_test, proofs, not_checked, seconds} and its Markdown
# twin verify.md for the PR body. head is the full commit the run checked; verdict is the first
# line of verify.md, `Verdict: pass at <head>` or `Verdict: fail at <head>`, on every report verify
# writes, the minimal fail report too, and verify.md ends with a `## Not checked` section that says
# none when empty. Evidence files live under <reports>/evidence/, which every run removes first and
# the evidence list fills.
# Commands come from .standards/config.json (build, test, mutation, languages[].format). build and
# test are a command, or a map with `command` and `paths`; test is also a list of {name, command,
# paths}, one check `tests <name>` each (scripts/_checks.py plan). A build or test command with
# paths runs when a changed file matches a glob, else it is a skipped check that says so. A test
# command that passed on the same command and the same files is not run again: the check is a pass
# that names the run it came from (lib/checks.sh); a command with no paths is reused only while the
# whole tree is unchanged, a failed one never, and --fresh runs every command. A build always runs:
# its outputs are ignored files, which a pass kept in another worktree cannot bring back. An empty
# mutation is the off switch (a skipped check); a mutation command with {files} runs on the changed
# source files only, like a format command, and is skipped when none changed. A project gate is
# `name: command` (always runs) or a map with `command:` and `paths:` (runs when a changed file
# matches a glob; otherwise a skipped check). After the gates, each entry of the `evidence` list in
# .flow/config.yaml, shaped like a gate, runs as the check `evidence <name>` with
# FLOW_EVIDENCE_FOLDER set to <reports>/evidence, where it writes its files; no gate sees that
# variable, and a failed capture fails verify. feel_test is true when a changed file matches
# feel_test_paths in the flow config. Never edits anything. The report is built from data by
# scripts/_verify_report.py and renamed into place, so it is never empty or half written; when it
# cannot be built, verify says why on stderr, writes a minimal report with status fail and the
# cause as a check summary, and exits 1. The changed files are those since the base: --base, else
# the claim's base (.flow/claim.json in the worktree, when a valid name) and the item state's,
# either alone when the other has none, else the config base; a claim base that differs from the
# item state's is neither, and the run has no base. A moved file is changed at its old path and its
# new one. When verify cannot trust the comparison, the base is unresolved, a git listing fails or
# a name holds U+001F, a failed `changed files` check names why (scripts/_change_list.py and
# scripts/_verify_base.py), every check with paths runs, no kept pass is reused and feel_test is
# true when feel_test_paths is set. Exit 0 on pass, 1 on fail; 2 when --base is not a valid name.
#
# verify.sh <item> --start [--base <ref>]: the same run, detached from the caller (its own session,
# stdin from /dev/null, output to <reports>/verify.out), so it outlives a shell call the host cuts
# short. Returns at once, exit 0. It records the run in <reports>/verify.run (lib/verify.sh) and
# first removes the earlier verify.json, verify.md and evidence/, so no report or evidence of an
# earlier run reads as this one's. A run of the item still going is not started again: --start says so and exits 0. The run
# lasts at most verify.limit from the flow config (s, m, h or d; default 2h): past it, its whole
# process group is stopped and the report is a fail naming the check that was running, the limit
# and any check that failed before it. A run stopped by a signal, or ended with no report, also
# leaves a fail report that says so.
# verify.sh <item> --wait [seconds]: waits up to the seconds (default 540) for the started run.
# Exit 0 when it passed and 1 when it failed, printing what the run printed, as the plain run
# does; 3 while it still runs, printing how long it has run and the check it is on. A run that died
# with no report (killed, crashed) is a fail: --wait writes the minimal fail report and exits 1. No
# run started: exit 2. A wait is no rerun. --detached is --start's own run, never called by hand.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
. "$FLOW_PLUGIN/lib/verify.sh"
. "$FLOW_PLUGIN/lib/checks.sh"
. "$FLOW_PLUGIN/lib/files_placeholder.sh"
usage="usage: verify.sh <item> [--base <ref>] [--fresh] [--start | --wait [seconds]]"
[ $# -ge 1 ] || die "$usage" 2
item="$1"; shift
# A --wait call by default: nine minutes, under the ten after which a host cuts a shell call.
default_wait_seconds=540; base=""; mode=run; wait_for="$default_wait_seconds"; fresh=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --fresh) fresh=fresh; shift ;;
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
export GIT_NO_REPLACE_OBJECTS=1 # a replace ref made in the worktree could forge the base commit's tree
main_worktree_resolve
[ -z "$base" ] || base_name_valid "$base" || die "--base takes a valid branch name" 2
item_state="$(adapter read "$item" 2>/dev/null)" || item_state='{}'
reports="$(reports_dir "$item" "$root")"; mkdir -p "$reports"
log="$reports/verify.log"; run_out="$reports/verify.out"
# The checks the run failed so far, one name per line, so a run stopped before its report still
# names them.
failed_file="$reports/verify.failed"

# next_attempt: the attempt this run is, one past the item's recorded attempts.
next_attempt() {
  recorded_attempts="$(state_get "$item_state" attempts)"; printf '%s' $(( ${recorded_attempts:-0} + 1 ))
}
# report_text <text>: the text as one line of printable characters with no quote or backslash,
# cut to report_text_max_characters, safe inside the JSON string of a minimal report.
report_text_max_characters=400
report_text() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | LC_ALL=C tr -d '"\\' | cut -c1-"$report_text_max_characters"; }
# fail_report <check name> <summary> <sentence> <stop cause>: the minimal report with status fail
# and one failed check, written without the builder and renamed in, with its verify.md twin saying
# the sentence. The stop cause (limit, signal or ended) is the report's `stopped`, empty for a
# report no stop made: advance.sh reads it, as a stopped run failed no check. Name, summary and
# sentence are report_text already; $attempts, $base and $head_sha (the full commit) are set. Each
# file is written to a new one mktemp makes, never through a link left at a name, and renamed in.
fail_report() {
  safe_name() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._/-'; }
  minimal_head="$(safe_name "$head_sha")"
  minimal_json_file="$(mktemp "$reports/.verify.json.XXXXXX")" && printf '{"status": "fail", "verdict": "Verdict: fail at %s", "checks": [{"name": "%s", "status": "fail", "command": "", "summary": "%s"}], "attempts": %d, "base": "%s", "head": "%s", "changed_files": [], "feel_test": false, "proofs": [], "not_checked": [], "stopped": "%s"}\n' \
    "$minimal_head" "$1" "$2" "$attempts" "$(safe_name "$base")" "$minimal_head" "$(safe_name "${4:-}")" > "$minimal_json_file" && mv -f "$minimal_json_file" "$reports/verify.json"
  minimal_md_file="$(mktemp "$reports/.verify.md.XXXXXX")" && printf 'Verdict: fail at %s\n\n## Checks (attempt %d)\n\n%s\n\nLog: `%s`.\n\n## Not checked\n\nNone.\n' "$minimal_head" "$attempts" "$3" "$log" \
    > "$minimal_md_file" && mv -f "$minimal_md_file" "$reports/verify.md"
}
# duration <seconds>: 45s, 12m 30s or 2h 05m.
seconds_per_minute=60; seconds_per_hour=3600
duration() {
  if [ "$1" -lt "$seconds_per_minute" ]; then printf '%ds' "$1"
  elif [ "$1" -lt "$seconds_per_hour" ]; then printf '%dm %02ds' $(($1 / seconds_per_minute)) $(($1 % seconds_per_minute))
  else printf '%dh %02dm' $(($1 / seconds_per_hour)) $(($1 % seconds_per_hour / seconds_per_minute)); fi
}
# now_seconds: the clock the seconds of each check and of the run read: FLOW_NOW_SECONDS when it is
# whole seconds since the epoch, else the system clock. It exists for tests, like FLOW_NOW in gate.sh.
now_seconds() { case "${FLOW_NOW_SECONDS:-}" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$FLOW_NOW_SECONDS" ;; esac; }
# limit_seconds: verify.limit from the flow config in seconds; a value that is no duration says so
# on stderr and returns 1.
limit_seconds() { cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds verify.limit "$(cfg_or verify.limit 2h)"; }
# running_now: the check the run is on, as the log names it, or starting before the first.
running_now() { current_check="$(verify_running_check "$log")"; printf '%s' "${current_check:-starting}"; }
# unfinished_report <cause> <stop cause>: the fail report of a run that ended with none, naming the
# check the log shows running and the cause, said on stdout and in the log. Exits 1. A check that
# failed before the stop is named too, and the report then has no stop cause: the run failed it.
unfinished_report() {
  running_header="$(verify_running_check "$log")"; unfinished_check="${running_header%%: *}"; unfinished_command="${running_header#*: }"
  if [ -n "$running_header" ]; then unfinished_summary="$(report_text "$1 while $unfinished_check ran ($unfinished_command)")"
  else unfinished_check=verify; unfinished_summary="$(report_text "$1 before the first check")"; fi
  failed_before="$(tr '\n' ',' < "$failed_file" 2>/dev/null | sed 's/,$//; s/,/, /g')"; reported_stop="$2"
  [ -z "$failed_before" ] || { unfinished_summary="$(report_text "$failed_before failed, then $unfinished_summary")"; reported_stop=""; }
  fail_report "$(report_text "$unfinished_check")" "$unfinished_summary" "Verify did not finish: $unfinished_summary." "$reported_stop"
  printf '\nverify: %s\n' "$unfinished_summary" >> "$log"
  echo "verify: fail (attempt $attempts): $unfinished_summary; report $reports/verify.json"
  exit 1
}

# say_live_run: true, saying how long it has run and the check it is on, while the item's run goes.
say_live_run() {
  live_run_pid="$(verify_run_live "$reports" "$item")" || return 1
  live_started="$(verify_run_field "$reports" started)"
  echo "verify: a run of $item is already going (pid $live_run_pid, $(duration $(( $(date +%s) - ${live_started:-$(date +%s)} ))) in, now: $(running_now)); wait for it with verify.sh $item --wait"
}
# make_run_files: removes the earlier run's record, reports, evidence, log and output, and makes the
# log and the output new, never written through a link someone left at a name: the evidence folder
# is named without a trailing slash, so a link there goes and the folder it points at stays.
make_run_files() {
  rm -f "$(verify_run_file "$reports")" "$reports/verify.json" "$reports/verify.md" "$log" "$run_out" "$failed_file"
  rm -rf "$reports/evidence" || return 1
  (set -C; : > "$log" && : > "$run_out")
}
# may_start: takes the item's verify lock, so two starts never run the checks twice. False, saying
# how far it is, while a run of the item still goes.
may_start() {
  flow_lock "verify-$(item_slug "$item")" || die "another verify start of $item holds its lock" 1
  ! say_live_run
}
# start_run: --start.
start_run() {
  may_start || exit 0
  limit="$(limit_seconds)" || exit 2
  make_run_files || die "could not remove the earlier evidence or create the log of the verify run of $item"
  pid="$(verify_run_start "$reports" "$run_out" "$limit" "$item" "$given_base" "$fresh")" || exit 1
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
      run_started="$(verify_run_field "$reports" started)"; run_limit="$(verify_run_field "$reports" limit)"
      echo "verify: still running after $(duration $((now - ${run_started:-$now}))) of its $(duration "${run_limit:-0}") limit, now: $(running_now); wait again with verify.sh $item --wait"
      exit 3
    fi
    sleep 1
  done
  cat "$run_out" 2>/dev/null
  if [ ! -f "$reports/verify.json" ]; then
    attempts="$(next_attempt)"; head_sha="$(verify_run_field "$reports" head)"
    unfinished_report "the verify run (pid $(verify_run_field "$reports" pid)) ended with no report, killed or crashed," ended
  fi
  [ "$(json_get "$(cat "$reports/verify.json")" status)" = pass ]
  exit
}

# child_ends_in_time <pid>: true when the plain run ends by itself, within the limit and before a
# signal sets stop_cause; false, with it still running, when either comes first.
child_ends_in_time() {
  while process_running "$1"; do
    [ -z "$stop_cause" ] && [ $(( $(date +%s) - started )) -lt "$limit" ] || return 1
    sleep 1
  done
}
# stopped_run_report <stop cause> <exit code>: the fail report of a run that left none: stopped
# at the limit, stopped by a signal, or ended on its own. Exits 1.
stopped_run_report() {
  case "$1" in
    limit) unfinished_report "stopped at the verify limit of $(duration "$limit") (verify.limit)" limit ;;
    signal) unfinished_report "stopped by a signal" signal ;;
    *) unfinished_report "the run ended (exit $2) with no report" ended ;;
  esac
}

# run_detached: --detached, the run --start starts as the leader of its own process group. Runs
# the plain run as its child and ends it at the limit or on a signal.
run_detached() {
  leads_own_group || die "--detached is the run --start starts; use verify.sh $item --start" 2
  limit="$(limit_seconds)" || exit 2
  started="$(date +%s)"; stop_cause=""
  trap 'stop_cause="${stop_cause:-signal}"' TERM INT HUP
  sh "$FLOW_PLUGIN/scripts/verify.sh" "$item" ${given_base:+--base "$given_base"} ${fresh:+--fresh} &
  child=$!
  child_ends_in_time "$child" || stop_cause="${stop_cause:-limit}"
  [ -z "$stop_cause" ] || verify_stop_group
  wait "$child"; code=$?
  [ ! -f "$reports/verify.json" ] || exit "$code"
  attempts="$(next_attempt)"; head_sha="$(git rev-parse HEAD)"
  stopped_run_report "$stop_cause" "$code"
}

case "$mode" in
  start) start_run ;;
  wait) wait_run ;;
  detached) run_detached ;;
esac

name_separator="$(printf '\037')"
std=""; [ -f .standards/config.json ] && std="$(cat .standards/config.json)"
rm -f "$log" "$failed_file"; rm -rf "$reports/evidence" || die "could not remove the earlier evidence $reports/evidence"; (set -C; : > "$log") || die "could not create the verify log $log"
attempts="$(next_attempt)"
overall="pass"
run_started="$(now_seconds)"
records=""; changed_list=""; timings=""; change_list_summary_file=""; chosen_base_file=""
# dash runs no EXIT trap on a signal, so INT and TERM clean up too, then die of the same signal
# so a parent shell sees it (an exit 130 would hide it).
trap 'rm -f ${records:+"$records"} ${changed_list:+"$changed_list"} ${timings:+"$timings"} ${change_list_summary_file:+"$change_list_summary_file"} ${chosen_base_file:+"$chosen_base_file"}' EXIT
trap 'trap - INT EXIT; rm -f ${records:+"$records"} ${changed_list:+"$changed_list"} ${timings:+"$timings"} ${change_list_summary_file:+"$change_list_summary_file"} ${chosen_base_file:+"$chosen_base_file"}; kill -INT $$' INT
trap 'trap - TERM EXIT; rm -f ${records:+"$records"} ${changed_list:+"$changed_list"} ${timings:+"$timings"} ${change_list_summary_file:+"$change_list_summary_file"} ${chosen_base_file:+"$chosen_base_file"}; kill -TERM $$' TERM
records="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
changed_list="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
timings="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
change_list_summary_file="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
chosen_base_file="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
unreadable_names_exit=3; incomplete_list_exit=4; listed_files_only=" among the files verify could list"
config_base="$(cfg_or base main)"
changed_units="$(python3 -I "$FLOW_PLUGIN/scripts/_change_list.py" --log="$log" --summary="$change_list_summary_file" \
  --chosen-base-file="$chosen_base_file" --given="$given_base" --claimed="$(claim_name "$root" base)" \
  --recorded="$(checked_name "$(state_get "$item_state" base)")" \
  --task-branch="$(checked_name "$(state_get "$item_state" branch)")" --fallback="$config_base")"
case "$?" in
  0) change_list=complete; listed_files_only="" ;;
  "$unreadable_names_exit") change_list=unreadable_names ;;
  "$incomplete_list_exit") change_list=incomplete ;;
  *) die "cannot read the changed file names" ;;
esac
{ IFS= read -r base_commit && IFS= read -r base; } < "$chosen_base_file" || die "cannot read the comparison base"
change_list_summary="$(cat "$change_list_summary_file")" || die "cannot read why the changed file list is short"

record() {
  # record <name> <status> <command> <summary source> <seconds> <reused from>: one check, four
  # NUL-terminated fields, and its line in the timings: the whole seconds it ran, then the run a
  # reused pass came from (empty for a check that ran). The report builder turns the source into
  # the summary; nothing here is JSON.
  printf '%s\000%s\000%s\000%s\000' "$1" "$2" "$3" "$4" >> "$records"
  printf '%s\t%s\n' "$5" "$6" >> "$timings"
}
failed() {
  # failed <name>: the run failed the check, kept in the failed file too.
  overall="fail"; printf '%s\n' "$1" >> "$failed_file"
}
skipped() {
  # skipped <name> <why>: a check that did not apply, kept in the report so the reader sees why.
  record "$1" skipped "" "$2" 0 ""
}
changed_unit_matches() {
  unit_rest="$changed_units"
  while [ -n "$unit_rest" ]; do
    unit_name="${unit_rest%%"$name_separator"*}"; unit_rest="${unit_rest#*"$name_separator"}"
    glob_match "$1" "$unit_name" && return 0
  done
  return 1
}
changed_matches() {
  # changed_matches <globs, one per line>: true when a changed file matches one of them.
  while IFS= read -r glob_line; do
    [ -n "$glob_line" ] || continue
    changed_unit_matches "$glob_line" && return 0
  done <<EOF_GLOBS
$1
EOF_GLOBS
  return 1
}
in_scope() { [ "$change_list" != complete ] || changed_matches "$1"; }
command_with_verify_base() {
  case "$1" in
    *'{verify_base}'*) printf '%s\n' "$1" | sed "s/{verify_base}/$base_commit/g" ;;
    *) printf '%s' "$1" ;;
  esac
}

run_with_names() {
  run_template="$1"; shift
  [ -n "$run_template" ] || { echo "the command is empty" >&2; return 1; }
  run_command="$(files_placeholder_expanded "$run_template")" || return 1
  run_names_escaped=""
  case "$run_command" in
    *format_names_escaped*) run_names_escaped="$(names_backslash_escaped "$@")" || { echo "a file name with a newline cannot go into a quoted {files}" >&2; return 1; } ;;
  esac
  format_names_escaped="$run_names_escaped" sh -c "$run_command" sh "$@"
}

log_check_files() {
  [ "$#" -eq 0 ] || { printf '  files:\n'; printf '    %s\n' "$@"; } >> "$log"
}

run_check() {
  # run_check <name> <command> <kind: gate|signal> [files]: true when the command passed.
  name="$1"; command="$2"; kind="$3"; files="${4:-}"
  IFS="$name_separator"; set -f; set -- $files; set +f; unset IFS
  printf '\n== %s: %s\n' "$name" "$command" >> "$log"
  log_check_files "$@"
  check_started="$(now_seconds)"; log_start="$(($(wc -c < "$log") + 1))"
  if run_with_names "$command" "$@" >> "$log" 2>&1; then check_status="pass"; summary="ok"
  else
    check_status="fail"; [ "$kind" = "signal" ] && check_status="signal"
    summary="$(tail -c "+$log_start" "$log")"
  fi
  [ "$check_status" = "fail" ] && failed "$name"
  record "$name" "$check_status" "$command" "$summary" "$(( $(now_seconds) - check_started ))" ""
  [ "$check_status" = "pass" ]
}

scoped_check() {
  # scoped_check <name> <command> <globs, one per line> <build|test>: a build or test command.
  # With globs it runs only when a changed file matches one. A test pass kept for the same command
  # and files (lib/checks.sh) is reported as that pass, named with its run, and nothing runs;
  # --fresh runs the command whatever is kept.
  if [ -n "$3" ] && ! in_scope "$3"; then skipped "$1" "no changed file under its paths"; return; fi
  set -- "$1" "$(command_with_verify_base "$2")" "$3" "$4"
  inputs_key="$(check_key "$2" "$3")"
  if [ "$4" = test ] && [ -z "$fresh" ] && [ "$change_list" = complete ] && reused_from="$(check_passed "$inputs_key")"; then
    printf '\n== %s: %s\nreused: it passed on the same command and files in the run of %s\n' "$1" "$2" "$reused_from" >> "$log"
    record "$1" pass "$2" "ok, reused: it passed on the same command and files in the run of $reused_from" 0 "$reused_from"
    return
  fi
  if run_check "$1" "$2" gate; then check_keep "$inputs_key" "$item" "$(git rev-parse --short HEAD 2>/dev/null)"
  else check_drop "$inputs_key"; fi
}

planned_checks() {
  # planned_checks <build|test> <name of the check when the config has none>: each command the
  # plan holds for the kind, as a scoped check.
  planned_count="$(json_length "$planned" "$1")"
  if [ "${planned_count:-0}" -eq 0 ]; then skipped "$2" "no $1 command in .standards/config.json"; return; fi
  planned_index=0
  while [ "$planned_index" -lt "$planned_count" ]; do
    scoped_check "$(json_get "$planned" "$1.$planned_index.name")" "$(json_get "$planned" "$1.$planned_index.command")" "$(json_list "$planned" "$1.$planned_index.paths")" "$1"
    planned_index=$((planned_index + 1))
  done
}

# A build or test entry the plan cannot read is a failed check that names the entry, and neither
# kind runs.
if ! planned="$(cached_python3 -I "$FLOW_PLUGIN/scripts/_checks.py" plan .standards/config.json 2>&1)"; then
  record config fail "" "$planned" 0 ""; failed config; planned='{"build": [], "test": []}'
fi
if [ "$change_list" != complete ]; then record "changed files" fail "" "$change_list_summary" 0 ""; failed "changed files"; fi
planned_checks build build
nlang="$(json_length "$std" languages)"; i=0; ran_format=0; all_files=""
while [ "$i" -lt "${nlang:-0}" ]; do
  lang="$(json_get "$std" "languages.$i")"
  extensions="$(json_list "$lang" extensions)"
  nf="$(json_length "$lang" format)"; j=0
  if [ "${nf:-0}" -gt 0 ] && [ -z "$extensions" ]; then
    record format fail "" "the language $(json_get "$lang" name) has a format command and no extensions, so verify cannot tell which changed files it covers" 0 ""; failed format; ran_format=1
  fi
  while [ "$j" -lt "${nf:-0}" ]; do
    prefix="$(json_get "$lang" "format.$j.prefix")"; command="$(json_get "$lang" "format.$j.command")"
    files="$(printf '%s' "$changed_units" | python3 -I "$FLOW_PLUGIN/scripts/_checks.py" existing "$prefix" "$extensions")"
    if [ -n "$files" ]; then run_check "format${prefix:+ $prefix}" "$command" gate "$files"; ran_format=1; all_files="$all_files$files"; fi
    j=$((j + 1))
  done
  i=$((i + 1))
done
[ "$ran_format" -eq 1 ] || skipped format "no changed source files under a format rule$listed_files_only"
planned_checks test tests
mutation="$(json_get "$std" mutation)"
if [ -z "$mutation" ]; then skipped mutation "mutation is empty in .standards/config.json (off)"
else
  case "$mutation" in
    *'{files}'*) if [ -n "$all_files" ]; then run_check mutation "$mutation" signal "$all_files"; else skipped mutation "no changed source files for the mutation run$listed_files_only"; fi ;;
    *) run_check mutation "$mutation" signal ;;
  esac
fi
for name in $(yaml_keys "$(config_file)" gates); do
  command="$(cfg "gates.$name")"; paths=""
  if [ -z "$command" ]; then command="$(cfg "gates.$name.command")"; paths="$(cfg "gates.$name.paths")"; fi
  [ -n "$command" ] || continue
  if [ -n "$paths" ] && ! in_scope "$paths"; then skipped "gate $name" "no changed file under its paths"; continue; fi
  run_check "gate $name" "$command" gate
done
evidence_names="$(yaml_keys "$(config_file)" evidence)"
if [ -n "$evidence_names" ] && ! mkdir -p "$reports/evidence"; then
  record evidence fail "" "the evidence folder $reports/evidence cannot be made" 0 ""; failed evidence; evidence_names=""
fi
[ -z "$evidence_names" ] || export FLOW_EVIDENCE_FOLDER="$reports/evidence"
for evidence_name in $evidence_names; do
  evidence_command="$(cfg "evidence.$evidence_name")"; evidence_paths=""
  if [ -z "$evidence_command" ]; then evidence_command="$(cfg "evidence.$evidence_name.command")"; evidence_paths="$(cfg "evidence.$evidence_name.paths")"; fi
  [ -n "$evidence_command" ] || continue
  if [ -n "$evidence_paths" ] && ! in_scope "$evidence_paths"; then skipped "evidence $evidence_name" "no changed file under its paths"; continue; fi
  run_check "evidence $evidence_name" "$evidence_command" gate
done
feel_test_paths="$(cfg feel_test_paths)"; feel=false
if [ -n "$feel_test_paths" ] && [ "$change_list" != complete ]; then feel=not_ruled_out
elif changed_matches "$feel_test_paths"; then feel=true; fi
printf '%s' "$changed_units" > "$changed_list"
head_sha="$(git rev-parse HEAD)"

report_failed() {
  # report_failed <cause>: the report builder failed. Say so, and leave a minimal report that
  # still parses, with status fail and the cause.
  cause="$(report_text "$1")"
  echo "verify: could not build the report: $cause" >&2
  fail_report report "could not build the report: $cause" "The report could not be built: $cause"
  exit 1
}
err="$(cached_python3 -I "$FLOW_PLUGIN/scripts/_verify_report.py" "$records" "$changed_list" "$reports" "$overall" "$attempts" "$base" "$base_commit" "$head_sha" "$feel" "$log" "$timings" "$(( $(now_seconds) - run_started ))" 2>&1 >/dev/null)" \
  || report_failed "$(printf '%s\n' "${err:-the report builder exited non-zero}" | grep -v '^ ' | tail -1 | tr '\n' ' ')"
echo "verify: $overall (attempt $attempts); report $reports/verify.json"
[ "$overall" = "pass" ]
