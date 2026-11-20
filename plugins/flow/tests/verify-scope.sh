#!/bin/sh
# verify-scope.sh: which build and test commands a verify run starts, on the local adapter in
# throwaway repos. A test command with paths runs only when a changed file matches a glob, and a
# skipped one says why; a command with no paths always runs; a build takes paths too. A test
# command that passed on the same command and files is not run again and names the run it came
# from; a changed file under its paths, a changed command, an uncommitted change, a failed run and
# --fresh each run it again. A build always runs. Every check carries its whole seconds and the report the run's total. A
# malformed entry is a failed check that names it. A run stopped at its limit leaves a report
# advance.sh keeps at verify, with no attempt counted, behind the escalation gate; one stopped
# after a check failed names it and goes back to implement. An epic whose step names a size moves
# on with no re-size gate.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
# The sandbox removes the folder on exit, which lets every held gate go.
. "$here/_verify_fixture.sh"

# switchable <name>: a command that passes, and fails while fail-<name> exists.
switchable() { printf '[ ! -f %s/fail-%s ]' "$work" "$1"; }
# test_entry <name> <glob>: one entry of a test list, a switchable command with one path glob.
test_entry() { python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "command": sys.argv[2], "paths": [sys.argv[3]]}))' "$1" "$(switchable "$1")" "$2"; }
# standards <build json> <test json>: commits .standards/config.json with the two values in the worktree.
standards() {
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"version": "1", "build": json.loads(sys.argv[2]), "test": json.loads(sys.argv[3]), "mutation": "", "languages": []}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1" "$2"
  git -C "$worktree" add -A && git -C "$worktree" commit -qm "config"
}
# committed <path>: one more commit in the worktree that adds or changes the file.
committed() { mkdir -p "$(dirname "$worktree/$1")" && date +%s%N >> "$worktree/$1" && echo "$1" >> "$worktree/$1" && git -C "$worktree" add -A && git -C "$worktree" commit -qm "change $1"; }
# check_status <name>: the status of the named check in the report; check_field <name> <field>: one field of it.
check_field() { python3 -c 'import json,sys; found=[check for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]]; print(found[0].get(sys.argv[3], "") if found else "no such check")' "$reports/verify.json" "$1" "$2"; }
check_status() { check_field "$1" status; }
# ran <name>: the named check passed in this run by running, with no kept pass behind it.
ran() { [ "$(check_status "$1")" = pass ] && [ -z "$(check_field "$1" reused_from)" ]; }
# reused <name>: the named check passed from a kept pass, which the report names.
reused() { [ "$(check_status "$1")" = pass ] && [ -n "$(check_field "$1" reused_from)" ]; }
passing_gate="  ok: 'true'"

echo "scope: a test command runs only when a changed file is under its paths"
new_item scoped "$passing_gate"
standards '"true"' "[$(test_entry server 'server/**'), $(test_entry docs 'docs/**')]"
committed server/handler.txt
verify >/dev/null 2>&1; scoped_code=$?
check "ChangeUnderOneTestCommandsPaths_RunsThatCommand: the server tests run, because server/handler.txt is under server/**" \
  'ran "tests server"'
check "ChangeOutsideATestCommandsPaths_SkipsThatCommand: the docs tests never start, because no changed file is under docs/**" \
  '[ "$(check_status "tests docs")" = skipped ]'
check "SkippedTestCommand_SaysWhy: the report gives the reason, so a reader knows the tests were not forgotten" \
  '[ "$(check_field "tests docs" summary)" = "no changed file under its paths" ]'
check "VerifyWithOneCommandSkipped_Passes: a skipped command is no failure" '[ "$scoped_code" -eq 0 ] && [ "$(report_status)" = pass ]'

echo "scope: a command that passed on the same inputs is not run again"
verify >/dev/null 2>&1
check "SecondVerifyOnTheSameFiles_DoesNotRunTheCommand: the server tests pass from the kept pass, because their command and files did not change" \
  'reused "tests server"'
check "ReusedCheck_NamesTheRunItCameFrom: the report names the item whose run passed, so the pass can be traced" \
  'check_field "tests server" reused_from | grep -q -- "$item"'
check "ReusedCheck_TakesNoTime: nothing ran, so its seconds are 0" '[ "$(check_field "tests server" seconds)" = 0 ]'
check "KeptPass_LivesInTheFlowHomeOfTheMainWorktree: every worktree of the clone reads one store, and none holds it in its own tree" \
  '[ -n "$(ls "$root/app/.flow/checks" 2>/dev/null)" ] && [ ! -e "$worktree/.flow/checks" ]'
committed server/handler.txt
verify >/dev/null 2>&1
check "FileUnderThePathsChanged_RunsTheCommandAgain: the server tests run, because the files they read changed" 'ran "tests server"'
committed notes/unrelated.txt
verify >/dev/null 2>&1
check "FileOutsideThePathsChanged_ReusesThePass: the server tests pass from the kept pass, because nothing under server/** changed" 'reused "tests server"'
verify --fresh >/dev/null 2>&1
check "VerifyFresh_RunsEveryCommand: the server tests run, because --fresh ignores what is kept" 'ran "tests server"'
printf 'edited\n' >> "$worktree/server/handler.txt"
verify >/dev/null 2>&1; ran "tests server"; first_uncommitted_ran=$?
verify >/dev/null 2>&1
check "UncommittedChangeUnderThePaths_AlwaysRunsTheCommand: both runs run the server tests, because an uncommitted file has no kept pass" \
  '[ "$first_uncommitted_ran" -eq 0 ] && ran "tests server"'
git -C "$worktree" checkout -q -- server/handler.txt
: > "$work/fail-server"
verify --fresh >/dev/null 2>&1
verify >/dev/null 2>&1; after_fresh_code=$?
rm -f "$work/fail-server"
check "FreshRunThatFails_DropsTheKeptPass: the next verify runs the server tests again and fails, because a known failure outranks an older pass" \
  '[ "$after_fresh_code" -eq 1 ] && [ "$(check_status "tests server")" = fail ]'

echo "scope: a file moved out of a command's paths runs that command"
new_item moved "$passing_gate"
standards '"true"' "[$(test_entry moved 'server/**')]"
committed server/handler.txt
git -C "$worktree" branch moved-base
mkdir -p "$worktree/docs" && git -C "$worktree" mv server/handler.txt docs/handler.txt && git -C "$worktree" commit -qm "move handler"
verify --base moved-base >/dev/null 2>&1
check "FileMovedOutOfTheCommandsPaths_RunsTheCommand: the tests under server/** run, because a file they read left it though git names the move by docs/ alone" \
  '[ "$(check_status "tests moved")" = pass ]'

echo "scope: a failed command is never reused, and a changed command runs"
new_item failing "$passing_gate"
standards '"true"' "[$(test_entry flaky 'src/**')]"
committed src/code.txt
: > "$work/fail-flaky"
verify >/dev/null 2>&1; failed_code=$?
rm -f "$work/fail-flaky"
verify >/dev/null 2>&1; passed_code=$?
check "CommandThatFailed_RunsAgainOnTheSameFiles: the second verify runs it and passes, because a fail is never kept" \
  '[ "$failed_code" -eq 1 ] && [ "$passed_code" -eq 0 ] && ran "tests flaky"'
python3 -c 'import json,sys; path=sys.argv[1]; config=json.load(open(path)); config["test"][0]["command"] += "; true"; json.dump(config, open(path, "w"))' "$worktree/.standards/config.json"
git -C "$worktree" commit -qam "another command"
verify >/dev/null 2>&1
check "CommandTextChanged_RunsAgain: the flaky tests run, because a pass is kept for one command text" 'ran "tests flaky"'

echo "scope: a command with no paths, and a build with paths"
new_item whole "$passing_gate"
standards "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1], "paths": ["engine/**"]}))' "$(switchable engine-build)")" \
  "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$(switchable everything)")"
verify >/dev/null 2>&1
check "TestCommandWithNoPaths_AlwaysRuns: the whole-tree tests ran, though no path names the changed file" \
  'ran tests'
check "BuildWithPathsAndNoChangeUnderThem_IsSkipped: the build never starts and says why" \
  '[ "$(check_status build)" = skipped ] && [ "$(check_field build summary)" = "no changed file under its paths" ]'
verify >/dev/null 2>&1
check "CommandWithNoPathsOnAnUnchangedTree_IsReused: the whole-tree tests pass from the kept pass, because not one file changed" 'reused tests'
committed anywhere/file.txt
verify >/dev/null 2>&1
check "CommandWithNoPathsAfterAnyChange_RunsAgain: the whole-tree tests run, because with no paths every file is an input" 'ran tests'
committed engine/core.txt
verify >/dev/null 2>&1
check "BuildWithAChangeUnderItsPaths_Runs: the build ran once the engine changed" 'ran build'
verify >/dev/null 2>&1
check "BuildOnTheSameFiles_RunsAgain: the build runs, because its outputs are ignored files a kept pass cannot bring back to this worktree" \
  'ran build'

echo "scope: every check carries its time"
new_item timed "$passing_gate"
slow_seconds=2
standards '"true"' "$(python3 -c 'import json,sys; print(json.dumps([{"name": "slow", "command": "sleep " + sys.argv[1], "paths": ["src/**"]}, {"name": "idle", "command": "true", "paths": ["docs/**"]}]))' "$slow_seconds")"
committed src/code.txt
verify >/dev/null 2>&1
check "CheckThatRan_CarriesItsWholeSeconds: the slow tests took at least the seconds they slept" \
  '[ "$(check_field "tests slow" seconds)" -ge "$slow_seconds" ]'
check "SkippedCheck_HasZeroSeconds: nothing ran" '[ "$(check_field "tests idle" seconds)" = 0 ]'
check "Report_CarriesTheTotalOfTheRun: the total covers at least the slow check" \
  '[ "$(json_value seconds < "$reports/verify.json")" -ge "$slow_seconds" ]'
check "VerifyMarkdown_ShowsTheTimeBesideEachCheck: the table has a time column and the run total" \
  'grep -q "^| check | status | time | summary |" "$reports/verify.md" && grep -q "^| tests idle | skipped | 0s |" "$reports/verify.md" && grep -q "^The run took " "$reports/verify.md"'
(export FLOW_NOW_SECONDS=1000; verify --fresh >/dev/null 2>&1)
check "ClockGivenToTheRun_TimesEveryCheck: the slow tests and the run take 0 seconds, because a clock that stands still is the one the run reads" \
  '[ "$(check_field "tests slow" seconds)" = 0 ] && [ "$(json_value seconds < "$reports/verify.json")" = 0 ]'

echo "scope: a malformed entry is named"
new_item malformed "$passing_gate"
standards '"true"' '[{"name": "nameless-command", "paths": ["src/**"]}]'
verify >/dev/null 2>&1; malformed_code=$?
check "TestEntryWithNoCommand_FailsVerifyAndNamesTheEntry: the config check fails and says which entry has no command" \
  '[ "$malformed_code" -eq 1 ] && [ "$(check_status config)" = fail ] && check_field config summary | grep -q "nameless-command has no command"'
printf '{"test": [{"name": "twice", "command": "true"}, {"name": "twice", "command": "false"}]}' > "$work/repeated-names.json"
repeated_said="$(python3 "$plugin/scripts/_checks.py" plan "$work/repeated-names.json" 2>&1)"; repeated_code=$?
check "TestNameUsedTwice_PlansNothingAndNamesIt: the plan exits 2 and says which name repeats, so no command runs under a name it shares" \
  '[ "$repeated_code" -eq 2 ] && printf "%s" "$repeated_said" | grep -q "the name twice is used more than once"'

echo "scope: a run stopped at its limit stays at verify"
limit_yaml="verify:
  limit: 1s
"
new_item stopped "$(held_gate stopped)"
limit_yaml=""
for earlier_step in implement test review; do
  printf '{"status":"done"}\n' > "$reports/$earlier_step.json"
  "$plugin/scripts/advance.sh" "$item" >/dev/null 2>&1; "$plugin/scripts/next.sh" "$item" >/dev/null 2>&1
done
verify --start >/dev/null 2>&1
wait_until_ended
check "RunStoppedAtTheLimit_ReportSaysItWasStopped: the report names the limit as the stop, so no reader takes it for a failed check" \
  '[ "$(report_status)" = fail ] && [ "$(json_value stopped < "$reports/verify.json")" = limit ]'
"$plugin/scripts/advance.sh" "$item" >/dev/null 2>&1; stopped_code=$?
check "VerifyStoppedAtTheLimit_StaysAtVerifyBehindTheEscalationGate: no step has anything to fix, so the item does not go back to implement" \
  '[ "$stopped_code" -eq 4 ] && [ "$(state "$item" step)" = verify ] && [ "$(state "$item" gate)" = escalation ]'
check "VerifyStoppedAtTheLimit_CountsNoAttempt: a run that failed no check uses up none of the three attempts" \
  '[ "$(state "$item" attempts)" = 0 ] || [ -z "$(state "$item" attempts)" ]'
: > "$work/release-stopped"

echo "scope: a run stopped after a check failed goes back to implement"
limit_yaml="verify:
  limit: 5s
"
new_item stopped-after-fail "$(held_gate late)"
limit_yaml=""
standards "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$(switchable broken-build)")" '""'
: > "$work/fail-broken-build"
for earlier_step in implement test review; do
  printf '{"status":"done"}\n' > "$reports/$earlier_step.json"
  "$plugin/scripts/advance.sh" "$item" >/dev/null 2>&1; "$plugin/scripts/next.sh" "$item" >/dev/null 2>&1
done
verify --start >/dev/null 2>&1
wait_until_ended
check "RunStoppedAfterAFailedCheck_ReportNamesTheFailureAndNoStop: the build failed before the limit, so the report says so and carries no stop" \
  '[ "$(report_status)" = fail ] && [ -z "$(json_value stopped < "$reports/verify.json")" ] && check_field "gate late" summary | grep -q "^build failed, then stopped at the verify limit"'
"$plugin/scripts/advance.sh" "$item" >/dev/null 2>&1; stopped_after_fail_code=$?
check "VerifyStoppedAfterAFailedCheck_GoesBackToImplement: a failed build has something to fix, so the item returns to implement with an attempt counted" \
  '[ "$stopped_after_fail_code" -eq 0 ] && [ "$(state "$item" step)" = implement ] && [ "$(state "$item" attempts)" = 1 ]'
: > "$work/release-late"

echo "scope: an epic's step that names a size raises no re-size gate"
new_repo epic-size
sized_epic="$("$local_adapter/create.sh" epic "Sized epic" --body x)"
epic_reports="$("$plugin/scripts/next.sh" "$sized_epic" --json 2>/dev/null | json_value reports)"
printf '{"status":"done","size":"L","summary":"interviewed"}\n' > "$epic_reports/grill.json"
"$plugin/scripts/advance.sh" "$sized_epic" >/dev/null 2>&1
check "EpicStepNamingASize_RaisesTheProfileGateOnly: the gate after grill is interview, never plan-approval, because an epic has no size to re-size" \
  '[ "$(state "$sized_epic" gate)" = interview ]'
"$plugin/scripts/gate.sh" clear "$sized_epic" "Confirmed." >/dev/null 2>&1
"$plugin/scripts/next.sh" "$sized_epic" >/dev/null 2>&1
printf '{"status":"done","size":"L","summary":"epic body written"}\n' > "$epic_reports/epic.json"
"$plugin/scripts/advance.sh" "$sized_epic" >/dev/null 2>&1; epic_code=$?
check "EpicStepNamingTheSameSizeAgain_MovesOn: the epic step ends with no gate and the tasks step is next, so the size cannot loop the item" \
  '[ "$epic_code" -eq 0 ] && [ "$(state "$sized_epic" gate)" = none ] && [ "$(state "$sized_epic" step)" = tasks ]'

if [ "$fails" -eq 0 ]; then echo "verify-scope: ok"; else echo "verify-scope: $fails failed"; exit 1; fi
