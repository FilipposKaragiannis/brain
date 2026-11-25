#!/bin/sh
# checks.sh: a project's own checks, run by the check job on their schedules, in a throwaway repo
# with a bare origin, the local adapter, the flow home in the repo's .flow as init leaves it, and a
# pool whose claimed worktree holds an uncommitted file. A check under jobs.checks is the schedule
# check-<name> in jobs.sh status, history and install, and the bare name check is none; a run
# checks the base out fresh from origin under the flow home, never in the pool, removes it however
# the run ends, and runs beside another check's run.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

# The polls a wait makes, and the seconds between two, before it gives up.
poll_limit=150
poll_delay=0.2
# The exit code the failing run of the probe check ends with.
probe_failure_code=3
# The seconds the slow check runs unless stopped: far longer than the polls wait.
slow_check_seconds=60
# The exit code jobs.sh gives a name or a setting it refuses.
refused_exit=2
# The runs history prints, and its rows: two header lines, then the newest run, then the one before.
history_runs_shown=5
newest_history_row=3
older_history_row=4
# wait_until '<condition>': true once the condition holds, false when the polls run out first.
wait_until() {
  poll_count=0
  until (eval "$1") >/dev/null 2>&1; do
    poll_count=$((poll_count + 1)); [ "$poll_count" -lt "$poll_limit" ] || return 1
    sleep "$poll_delay"
  done
}
# report_line <report> <field>: the value the probe wrote for the field.
report_line() { sed -n "s/^$2 //p" "$1"; }
# history_row <schedule> <row>: one row of the schedule's history table.
history_row() { "$jobs_script" history "$1" "$history_runs_shown" | sed -n "$2p"; }
# run_probe <exit code>: one run of the smoke check, whose probe ends with the exit code; the run's
# own exit code is the function's.
run_probe() {
  echo "$1" > "$work/probe.exit"; rm -f "$work/probe.report"
  "$check_job" claude --as check-smoke > "$work/run.out" 2>&1
}
jobs_script="$plugin/scripts/jobs.sh"
check_job="$plugin/jobs/check.sh"

new_repo checks
# The folders as git names them, links resolved: the checkout's pwd comes from git's worktree list.
repository_folder="$(cd "$root" && pwd -P)"
flow_home_folder="$repository_folder/app/.flow"
cat > "$work/probe.sh" <<SH
printf 'pwd %s\n' "\$(pwd)" > "$work/probe.report"
printf 'head %s\n' "\$(git rev-parse HEAD)" >> "$work/probe.report"
printf 'status %s\n' "\$(git status --porcelain | tr '\n' ' ')" >> "$work/probe.report"
printf 'files %s\n' "\$(ls -A | tr '\n' ' ')" >> "$work/probe.report"
echo "probe ends with \$(cat "$work/probe.exit")"
exit "\$(cat "$work/probe.exit")"
SH
cat > "$work/slow.sh" <<SH
pwd > "$work/slow.started"
sleep $slow_check_seconds
SH
cat > "$flow_home_folder/config.yaml" <<YAML
adapters:
  default: local
base: main
pool:
  - ../wt-1
  - ../wt-2
notify:
  desktop: false
jobs:
  schedule:
    health: every 15m
  checks:
    smoke:
      command: sh $work/probe.sh
      schedule: daily 02:00
    slow:
      command: sh $work/slow.sh
      schedule: every 2h
YAML
claimed_item="$(new_task "Claimed work")"
claimed_worktree="$("$plugin/scripts/steward.sh" claim "$claimed_item")"
printf 'work in progress\n' > "$claimed_worktree/uncommitted-work.txt"
claimed_worktree_before="$(git -C "$claimed_worktree" rev-parse HEAD; git -C "$claimed_worktree" status --porcelain; cat "$claimed_worktree/uncommitted-work.txt")"
remote_commit main pushed-to-origin.txt
origin_main="$(git -C "$root/origin.git" rev-parse main)"

echo "checks: a check's checkout"
run_probe 0
cp "$work/probe.report" "$work/pass.report"
pass_checkout="$(report_line "$work/pass.report" pwd)"
check "PassingCheck_RunsUnderTheFlowHomesCheckRuns: the check runs in its own folder under <flow home>/check-runs" \
  'case "$pass_checkout" in "$flow_home_folder/check-runs/"?*) ;; *) exit 1 ;; esac'
check "PassingCheck_RunsInNoPoolWorktree: the folder is none of the pool's" \
  '[ -n "$pass_checkout" ] && case "$pass_checkout" in "$repository_folder/wt-"*|"$root/wt-"*) exit 1 ;; esac'
check "CommitPushedToOrigin_IsTheCheckoutsHead: the run fetches the base, so a commit only origin holds is what the check sees" \
  '[ -n "$origin_main" ] && [ "$(report_line "$work/pass.report" head)" = "$origin_main" ]'
check "FreshCheckout_HasACleanStatus: the check sees the base as committed, with nothing changed or untracked" \
  '[ -n "$(report_line "$work/pass.report" files)" ] && [ -z "$(report_line "$work/pass.report" status | tr -d " ")" ]'
check "ClaimedWorktreeWithUncommittedWork_StaysOutOfTheCheckout: a file only the claimed worktree holds is not where the check runs" \
  '[ -f "$claimed_worktree/uncommitted-work.txt" ] && [ -n "$(report_line "$work/pass.report" files)" ] && ! report_line "$work/pass.report" files | grep -q "uncommitted-work.txt"'
check "ClaimedWorktree_IsUnchangedByARun: the run leaves the claimed worktree's commit, status and files as they were" \
  '[ -f "$claimed_worktree/uncommitted-work.txt" ] && [ "$(git -C "$claimed_worktree" rev-parse HEAD; git -C "$claimed_worktree" status --porcelain; cat "$claimed_worktree/uncommitted-work.txt")" = "$claimed_worktree_before" ]'
check "PassingRun_RemovesItsCheckout: the folder goes when the run ends" \
  '[ -n "$pass_checkout" ] && [ ! -e "$pass_checkout" ]'
run_probe "$probe_failure_code"; failing_run_exit=$?
fail_checkout="$(report_line "$work/probe.report" pwd)"
check "FailingCheck_EndsTheRunFailed: a command that exits non-zero fails the run" \
  '[ "$failing_run_exit" -ne 0 ]'
check "FailingRun_RemovesItsCheckout: the folder goes when the run fails too" \
  '[ -n "$fail_checkout" ] && [ ! -e "$fail_checkout" ]'

echo "checks: a check's schedule"
"$jobs_script" status --json > "$work/status.json"
check "CheckInTheConfig_IsAStatusRowOfTheCheckJob: jobs.checks.smoke is the schedule check-smoke, run by the check job" \
  'python3 -c "import json,sys; rows={row[\"name\"]: row for row in json.load(open(sys.argv[1]))}; assert rows[\"check-smoke\"][\"job\"] == \"check\", rows" "$work/status.json"'
check "CheckInTheConfig_StatusRowHasItsSchedule: the row's schedule is the entry's" \
  'python3 -c "import json,sys; rows={row[\"name\"]: row for row in json.load(open(sys.argv[1]))}; assert rows[\"check-smoke\"][\"schedule\"] == \"daily 02:00\", rows" "$work/status.json"'
check "ChecksInTheConfig_ListNoBareCheckRow: the check job runs only as check-<name>, so status has no row named check" \
  'python3 -c "import json,sys; names=[row[\"name\"] for row in json.load(open(sys.argv[1]))]; assert names and \"check\" not in names, names" "$work/status.json"'
check "PlainScheduleBesideChecks_KeepsItsSchedule: a jobs.schedule entry still reads as before" \
  'python3 -c "import json,sys; rows={row[\"name\"]: row for row in json.load(open(sys.argv[1]))}; assert rows[\"health\"][\"schedule\"] == \"every 15m\", rows[\"health\"]" "$work/status.json"'
check "PassThenFail_StatusShowsTheLastResultAndItsLength: the row's last run is the failed one, with how long it took" \
  '"$jobs_script" status | grep -Eq "^\| check-smoke \| daily 02:00 \| [^|]* \| [^|]+ \| [0-9]+(m [0-9]+)?s \| failed: failed: exited $probe_failure_code at "'
check "PassThenFail_HistoryShowsTheFailedRunFirst: history lists the newest run first, failed with its exit code" \
  'history_row check-smoke "$newest_history_row" | grep -q "| check-smoke | [^|]* | 1 | failed | failed: exited $probe_failure_code at "'
check "PassThenFail_HistoryShowsThePassingRunSecond: the run before it passed, at the base's commit" \
  'history_row check-smoke "$older_history_row" | grep -q "| check-smoke | [^|]* | 0 | work | done: passed at "'
check "BareCheckName_IsRefusedByHistory: check is no schedule, so history refuses it" \
  '"$jobs_script" history check; [ $? -eq "$refused_exit" ]'
export FLOW_SCHEDULER=launchd FLOW_LAUNCH_AGENTS="$work/agents"
"$jobs_script" install check-smoke > "$work/install-no-wrapper.out" 2>&1; install_without_wrapper_exit=$?
check "CheckWithoutItsWrapper_IsNotInstalled: install refuses the check while .flow/jobs/check.sh is missing" \
  '[ "$install_without_wrapper_exit" -eq "$refused_exit" ]'
check "CheckWithoutItsWrapper_InstallSaysToRunInit: the refusal names flow:init, which installs the wrapper" \
  'grep -q "flow:init" "$work/install-no-wrapper.out"'
mkdir -p .flow/jobs && printf '#!/bin/sh\nexec "%s" "$@"\n' "$check_job" > .flow/jobs/check.sh && chmod +x .flow/jobs/check.sh
"$jobs_script" install check-smoke > "$work/install.out" 2>&1
check_plist="$work/agents/com.app.flow.check-smoke.plist"
check "CheckWithItsWrapper_InstallsAnAgentThatRunsTheCheckJobAsItsSchedule: the agent runs the wrapper with the host and --as check-smoke" \
  'python3 -c "import plistlib,sys; command=plistlib.load(open(sys.argv[1], \"rb\"))[\"ProgramArguments\"][-1]; assert command.split()[-4:] == [\".flow/jobs/check.sh\", \"claude\", \"--as\", \"check-smoke\"], command" "$check_plist"'
unset FLOW_SCHEDULER FLOW_LAUNCH_AGENTS

echo "checks: two checks at once, and a stop"
"$check_job" claude --as check-slow > "$work/slow.out" 2>&1 &
slow_run=$!
wait_until '[ -s "$work/slow.started" ]'
run_probe 0
check "CheckWhileAnotherCheckRuns_RunsAsWell: checks take no shared lock, so a long one makes no other skip" \
  'history_row check-smoke "$newest_history_row" | grep -q "| work | done: passed at "'
slow_checkout="$(cat "$work/slow.started")"
FLOW_SCHEDULER=cron "$jobs_script" stop check-slow > "$work/stop.out" 2>&1
wait_until '! kill -0 "$slow_run"'
check "StoppedRun_RemovesItsCheckout: jobs.sh stop mid-run ends the command and the folder goes" \
  '[ -n "$slow_checkout" ] && [ ! -e "$slow_checkout" ]'
kill "$slow_run" 2>/dev/null

[ "$fails" -eq 0 ] && { echo "checks: ok"; exit 0; }
echo "checks: $fails failed"; exit 1
