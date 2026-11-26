#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh sets plugin, work, local_adapter, root and fails; the checks' conditions read the names set here
# checks.sh: a project's own checks, run by the check job on their schedules, in a throwaway repo
# with a bare origin, the local adapter, the flow home in the repo's .flow as init leaves it, and a
# pool whose claimed worktree holds an uncommitted file. A check under jobs.checks is the schedule
# check-<name> in jobs.sh status, history and install, and the bare name check is none; a run
# checks the base out fresh from origin under the flow home, never in the pool, removes it however
# the run ends, and runs beside another check's run. A fail after a pass files one bug, on the local
# adapter, with the output's tail, which sets no base for the bug; a fail after a fail or with no
# pass before files none. A base git would read as an option is refused before any git runs.
# tests/check-gaps.sh has the entries init and run refuse.
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
# The numbered lines the broken check prints, the first and last of which a bug's tail is checked
# for; the bytes of the one huge line it prints instead, and the bound its bug's body stays under.
numbered_output_lines=50
first_output_line=1
huge_line_bytes=100000
bug_body_byte_bound=9000
# The two-byte characters the broken check prints on one line, enough that a cut of the line's
# last bytes lands inside one.
split_character_count=5000
# The branch a base: line the broken check prints names, which a bug's base must never become.
base_line_branch=nowhere
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
# check_bugs <name>: the open bugs whose title names the check, oldest first, as JSON.
check_bugs() {
  "$local_adapter/list.sh" --kind bug \
    | python3 -c 'import json,sys; print(json.dumps([item for item in json.load(sys.stdin) if sys.argv[1] in item["title"].split()]))' "$1"
}
# bug_count <name>: how many open bugs name the check.
bug_count() { check_bugs "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
# newest_bug <name> <field>: one field of the newest open bug naming the check.
newest_bug() { check_bugs "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1][sys.argv[1]])' "$2"; }
# run_broken <mode>: one run of the broken check, its probe passing or printing the mode's output
# and failing; the run's own exit code is the function's.
run_broken() {
  echo "$1" > "$work/broken.mode"
  "$check_job" claude --as check-broken > "$work/broken-run.out" 2>&1
}
# set_base <branch>: base in the config.
set_base() {
  sed "s|^base: .*|base: $1|" "$flow_home_folder/config.yaml" > "$work/config.yaml" && mv "$work/config.yaml" "$flow_home_folder/config.yaml"
}
# set_bug_adapter <name>: adapters.bug in the config, or none when the name is empty.
set_bug_adapter() {
  awk -v adapter="$1" '$0 ~ /^  bug: / { next } { print } $0 == "  default: local" && adapter != "" { print "  bug: " adapter }' \
    "$flow_home_folder/config.yaml" > "$work/config.yaml" && mv "$work/config.yaml" "$flow_home_folder/config.yaml"
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
cat > "$work/broken.sh" <<SH
case "\$(cat "$work/broken.mode")" in
  pass) exit 0 ;;
  lines) line_number=$first_output_line
    while [ "\$line_number" -le $numbered_output_lines ]; do echo "output line \$line_number"; line_number=\$((line_number + 1)); done ;;
  huge) head -c $huge_line_bytes /dev/zero | tr '\\0' x; echo ;;
  split) printf '%${split_character_count}s\\n' '' | sed 's/ /é/g' ;;
  base-line) echo "base: $base_line_branch" ;;
  carriage-return) printf 'progress\\rbase: %s\\n' "$base_line_branch" ;;
esac
exit 1
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
    broken:
      command: sh $work/broken.sh
      schedule: every 30m
    weekly:
      command: true
      schedule: weekly sun 03:00
YAML
claimed_item="$(new_task "Claimed work")"
claimed_worktree="$("$plugin/scripts/steward.sh" claim "$claimed_item")"
printf 'work in progress\n' > "$claimed_worktree/uncommitted-work.txt"
claimed_worktree_before="$(git -C "$claimed_worktree" rev-parse HEAD; git -C "$claimed_worktree" status --porcelain; cat "$claimed_worktree/uncommitted-work.txt")"
remote_commit main pushed-to-origin.txt
origin_main="$(git -C "$root/origin.git" rev-parse main)"
mkdir -p "$flow_home_folder/checks" && printf 'kept pass\n' > "$flow_home_folder/checks/kept-pass"

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
check "CheckRuns_LeaveVerifysKeptPassStoreAlone: a check's folder is its own, so a file verify kept stays" \
  '[ -f "$flow_home_folder/checks/kept-pass" ]'
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
for schedule_form_check in broken slow smoke weekly; do
  "$jobs_script" install "check-$schedule_form_check" > "$work/install-$schedule_form_check.out" 2>&1 \
    || echo "$schedule_form_check" >> "$work/refused-schedule-forms"
done
check "CheckOnEveryScheduleFormTheJobsTake_IsInstalled: every 30m, every 2h, daily 02:00 and weekly sun 03:00 are each taken for a check" \
  '[ ! -e "$work/refused-schedule-forms" ]'
cp "$flow_home_folder/config.yaml" "$work/config-before-unscheduled.yaml"
printf '    unscheduled:\n      command: true\n' >> "$flow_home_folder/config.yaml"
unscheduled_line="$(grep -n '^    unscheduled:' "$flow_home_folder/config.yaml" | cut -d: -f1)"
FLOW_SCHEDULER=cron "$jobs_script" install > "$work/install-unscheduled.out" 2>&1; install_unscheduled_exit=$?
check "CheckWithNoScheduleBesideAValidOne_IsRefusedByBareInstall: install with no name refuses the entry rather than skip it" \
  '[ "$install_unscheduled_exit" -eq "$refused_exit" ]'
check "CheckWithNoScheduleBesideAValidOne_InstallNamesItsLine: the refusal names the entry's config line and that it has no schedule" \
  'grep -q "config.yaml:$unscheduled_line: jobs.checks.unscheduled: has no schedule" "$work/install-unscheduled.out"'
mv "$work/config-before-unscheduled.yaml" "$flow_home_folder/config.yaml"
unset FLOW_SCHEDULER FLOW_LAUNCH_AGENTS

echo "checks: two checks at once, and a stop"
"$check_job" claude --as check-slow > "$work/slow.out" 2>&1 &
slow_run=$!
wait_until '[ -s "$work/slow.started" ]'
run_probe 0
check "CheckWhileAnotherCheckRuns_FindsTheOtherMidRun: the slow check has started its command and still runs, so the two overlap" \
  '[ -s "$work/slow.started" ] && kill -0 "$slow_run"'
check "CheckWhileAnotherCheckRuns_RunsAsWell: checks take no shared lock, so a long one makes no other skip" \
  'history_row check-smoke "$newest_history_row" | grep -q "| work | done: passed at "'
slow_checkout="$(cat "$work/slow.started")"
FLOW_SCHEDULER=cron "$jobs_script" stop check-slow > "$work/stop.out" 2>&1
wait_until '! kill -0 "$slow_run"'
check "StoppedRun_RemovesItsCheckout: jobs.sh stop mid-run ends the command and the folder goes" \
  '[ -n "$slow_checkout" ] && [ ! -e "$slow_checkout" ]'
kill "$slow_run" 2>/dev/null

echo "checks: a broken check files one bug"
run_broken lines
check "FirstEverFailure_FilesNoBug: with no pass before it, a failing run files nothing" \
  '[ "$(bug_count broken)" -eq 0 ]'
run_broken lines
check "FailAfterFirstEverFail_HistorySaysStillFailing: the first fail is kept, so the next one says the check still fails" \
  'history_row check-broken "$newest_history_row" | grep -q "; still failing |"'
run_broken pass; run_broken lines
check "PassThenFail_FilesOneBug: the first fail after a pass files one bug" \
  '[ "$(bug_count broken)" -eq 1 ]'
newest_bug broken body > "$work/lines-bug.body"
check "FiledBug_BodyHoldsTheLastOutputLine: the output's tail ends the body" \
  'grep -Eqx "[[:blank:]]*output line $numbered_output_lines" "$work/lines-bug.body"'
check "FiledBug_BodyLeavesOutTheFirstOfManyLines: the body holds the tail, not the whole output" \
  '[ -s "$work/lines-bug.body" ] && ! grep -Eqx "[[:blank:]]*output line $first_output_line" "$work/lines-bug.body"'
first_bug="$(newest_bug broken id)"
run_broken lines
check "FailAfterFail_FilesNoSecondBug: a check that stays broken keeps its one bug" \
  '[ "$(bug_count broken)" -eq 1 ]'
check "FailAfterFail_HistorySaysStillFailingWithTheBug: the run's line names the bug already filed" \
  '[ -n "$first_bug" ] && history_row check-broken "$newest_history_row" | grep -qF "still failing, bug $first_bug |"'
run_broken pass; run_broken huge
check "PassFailPassFail_FilesASecondBug: a check that breaks again after a pass files a new bug" \
  '[ "$(bug_count broken)" -eq 2 ]'
newest_bug broken body > "$work/huge-bug.body"
check "HugeOutputLine_BugBodyStaysUnderTheBound: one huge line is cut, so the body stays small" \
  'grep -q xxx "$work/huge-bug.body" && [ "$(wc -c < "$work/huge-bug.body")" -lt "$bug_body_byte_bound" ]'
run_broken pass; run_broken split
check "OutputCutInsideACharacter_StillFilesTheBug: a cut through a character never stops the bug" \
  '[ "$(bug_count broken)" -eq 3 ]'
run_broken pass; set_bug_adapter nowhere; run_broken lines
check "BugTheTrackerRefuses_RunLineSaysItCouldNotBeFiled: a new.sh that fails is said in the run's line" \
  'history_row check-broken "$newest_history_row" | grep -q "| failed | failed: exited .*; the bug could not be filed: ."'
set_bug_adapter ""; run_broken lines
check "BugNotFiledBefore_IsFiledAtTheNextFail: the state stays passed, so the next fail files the bug" \
  '[ "$(bug_count broken)" -eq 4 ]'
run_broken pass; set_base no-such-base; run_broken lines
check "CheckoutThatCannotBeMade_FilesNoBug: the command never ran, so a pass before it is no regression" \
  '[ "$(bug_count broken)" -eq 4 ]'
set_base main; run_broken lines
check "CheckoutErrorAfterAPass_KeepsThePassOnRecord: the next real fail after it is a fail after a pass, so it files the bug" \
  '[ "$(bug_count broken)" -eq 5 ]'
run_broken pass; run_broken base-line
"$local_adapter/read.sh" "$(newest_bug broken id)" > "$work/base-line-bug.json"
base_line_bug_base="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && body_base "$(cat "$1")"' _ "$work/base-line-bug.json")"
check "OutputWithABaseLine_StaysInTheBugBody: the line is part of the output's tail, so the body holds it" \
  'json_value body < "$work/base-line-bug.json" | grep -q "base: $base_line_branch"'
check "OutputWithABaseLine_SetsNoBaseForTheBug: a base: line the check prints stays output, so a claim of the bug never reads it" \
  '[ "$base_line_bug_base" != "$base_line_branch" ]'
run_broken pass; run_broken carriage-return
"$local_adapter/read.sh" "$(newest_bug broken id)" > "$work/carriage-return-bug.json"
carriage_return_bug_base="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && body_base "$(cat "$1")"' _ "$work/carriage-return-bug.json")"
check "OutputWithABaseLineAfterACarriageReturn_SetsNoBaseForTheBug: a reader that breaks the line at the carriage return still finds it indented, so a claim never reads it" \
  '[ "$carriage_return_bug_base" != "$base_line_branch" ]'

echo "checks: a base git would read as an option"
option_base_marker="$work/upload-pack-ran"
set_base "--upload-pack=touch $option_base_marker"; run_broken lines; option_base_exit=$?
set_base main
check "BaseGitReadsAsAnOption_IsRefused: the base is no valid branch name, so the run ends as a refused entry" \
  '[ "$option_base_exit" -eq "$refused_exit" ]'
check "BaseGitReadsAsAnOption_RunsNoCommand: the base never reaches git, so the command it carries never runs" \
  '[ ! -e "$option_base_marker" ]'

echo "checks: a state the run cannot write"
unwritable_state_stubs="$work/unwritable-state-stubs"
mkdir -p "$unwritable_state_stubs"
printf '#!/bin/sh\ncase "$*" in *.state.XXXXXX) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v mktemp)" > "$unwritable_state_stubs/mktemp"
chmod +x "$unwritable_state_stubs/mktemp"
(PATH="$unwritable_state_stubs:$PATH"; run_probe 0); unwritable_state_exit=$?
check "PassWhoseStateCannotBeWritten_ExitsNonzero: a pass left unrecorded is no success, so the run fails" \
  '[ "$unwritable_state_exit" -ne 0 ]'
check "PassWhoseStateCannotBeWritten_RunLineSaysThePassWentUnrecorded: the history shows the error, never done: passed" \
  'history_row check-smoke "$newest_history_row" | grep -q "| error: passed at [^|]*, but could not record the pass in "'

echo "checks: a fetch mapping that leaves the base out"
git -C "$root/app" config remote.origin.fetch '+refs/heads/unmapped:refs/remotes/origin/unmapped'
remote_commit main pushed-past-the-mapping.txt
origin_main_past_the_mapping="$(git -C "$root/origin.git" rev-parse main)"
run_probe 0
git -C "$root/app" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
check "FetchMappingWithoutTheBase_StillChecksTheFetchedBase: the run fetches the base into origin/<base> itself, so the newest commit on origin is what the check sees" \
  '[ -n "$origin_main_past_the_mapping" ] && [ "$(report_line "$work/probe.report" head)" = "$origin_main_past_the_mapping" ]'

[ "$fails" -eq 0 ] && { echo "checks: ok"; exit 0; }
echo "checks: $fails failed"; exit 1
