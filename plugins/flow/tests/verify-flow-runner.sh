#!/bin/sh
# verify-flow-runner.sh: verify on the local adapter in throwaway repos. A check's output reaches
# the verify log while the check still runs. The flow entry of .standards/config.json runs this
# checkout's suite runner on stub suites: a change to one suite runs that suite alone and its lines
# reach the log under its name; a new folder, an unresolved base, a renamed suite and a deleted
# suite each run every suite; one lane and three lanes both pass; a failing assertion fails verify
# and the report names its suite.
# Exit 0 when every check passes, 1 on any failure.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

# standards_with_test <name> <command>: commits .standards/config.json with one test command.
standards_with_test() {
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"test": [{"name": sys.argv[2], "command": sys.argv[3]}]}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1" "$2"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "config"
}

new_item streaming ""
standards_with_test slow "printf '%s-%s\\n' started slow-check; while [ ! -f '$work/release-slow' ] && [ -d '$work' ]; do sleep 0.2; done"
verify >/dev/null 2>&1 &
streaming_verify=$!
until_true 60 'grep -q started-slow-check "$reports/verify.log"'; seen_while_running=$?
: > "$work/release-slow"
wait "$streaming_verify"
check "CheckStillRunning_HasItsOutputInTheLog because a run stopped at its limit must show where it stood" \
  '[ "$seen_while_running" -eq 0 ]'

marketplace="$plugin/../.."
new_item runner ""
stub_suites="$worktree/plugins/flow/tests"
mkdir -p "$worktree/tools/lib" "$worktree/.standards" "$stub_suites"
cp "$marketplace/tools/lib/flow_suites.py" "$worktree/tools/lib/"
cp "$marketplace/tools/test.sh" "$worktree/tools/"
python3 -c 'import json,sys; flow=[entry for entry in json.load(open(sys.argv[1]))["test"] if entry["name"]=="flow"]; json.dump({"test": flow}, open(sys.argv[2], "w"))' \
  "$marketplace/.standards/config.json" "$worktree/.standards/config.json"
for stub in run adapter-contract sessions holds base-claim base-readers; do printf 'echo "  ok   Stub_Holds"\n' > "$stub_suites/$stub.sh"; done
git -C "$worktree" add tools .standards plugins && git -C "$worktree" commit -qm "stub marketplace"
# base_here: the next change is compared with the worktree's HEAD, through the scenario-base branch.
base_here() { git -C "$worktree" branch -f scenario-base HEAD; }
# commit_all <message>: commits every change under plugins/flow in the worktree.
commit_all() { git -C "$worktree" add -A plugins && git -C "$worktree" commit -qm "$1"; }
flow_status() { python3 -c 'import json,sys; print([check["status"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]=="tests flow"][0])' "$reports/verify.json"; }
flow_summary() { python3 -c 'import json,sys; print([check["summary"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]=="tests flow"][0])' "$reports/verify.json"; }
# every_suite_ran: the flow check ran, and the log shows the inline section and the jira contract,
# which only a run of every suite starts.
every_suite_ran() { [ "$(flow_status)" = pass ] && grep -q '^flow: inline pass' "$reports/verify.log" && grep -q '^flow: contract-jira pass' "$reports/verify.log"; }

base_here
printf 'echo "  ok   Stub_StillHolds"\n' >> "$stub_suites/sessions.sh"
commit_all "sessions"
verify --base scenario-base >/dev/null 2>&1; one_suite_result=$?
check "OneChangedSuite_RunsAloneThroughVerify because the runner narrows a change to the suite it names" \
  '[ "$one_suite_result" -eq 0 ] && grep -qx "flow: selected sessions" "$reports/verify.log"'
check "PassingSuite_HasItsLinesInTheLogUnderItsName because a pass needs its evidence" \
  'grep -qx "\[sessions\]   ok   Stub_StillHolds" "$reports/verify.log"'

base_here
mkdir -p "$worktree/plugins/flow/new-runtime" && echo 'exit 0' > "$worktree/plugins/flow/new-runtime/check.sh"
commit_all "new folder"
verify --base scenario-base >/dev/null 2>&1
check "FileInANewFlowFolder_RunsEverySuite because verify must not skip what no path names" 'every_suite_ran'

verify --base no-such-base >/dev/null 2>&1
check "UnresolvedBase_RunsEverySuite because the change set is unknown" \
  'every_suite_ran && grep -q "no comparison base available" "$reports/verify.log"'

base_here
git -C "$worktree" mv plugins/flow/tests/sessions.sh plugins/flow/tests/renamed-sessions.sh
commit_all "rename"
verify --base scenario-base >/dev/null 2>&1
check "RenamedSuite_RunsEverySuite because the old path names no suite" 'every_suite_ran'

base_here
git -C "$worktree" rm -q plugins/flow/tests/holds.sh
commit_all "delete"
verify --base scenario-base >/dev/null 2>&1
check "DeletedSuite_RunsEverySuite because what it covered is unknown" 'every_suite_ran'

for lanes in 1 3; do
  (FLOW_SUITE_LANES="$lanes"; export FLOW_SUITE_LANES; verify --fresh --base no-such-base >/dev/null 2>&1)
  check "LaneCount${lanes}_RunsEverySuite because any whole count from 1 must work" 'every_suite_ran'
done
(FLOW_SUITE_LANES=0; export FLOW_SUITE_LANES; verify --fresh --base no-such-base >/dev/null 2>&1)
check "LaneCountZero_FailsTheFlowCheck because the variable reaches the runner through verify" \
  '[ "$(flow_status)" = fail ] && flow_summary | grep -q "FLOW_SUITE_LANES takes a whole number from 1"'

base_here
printf 'echo "  FAIL StubAssertion_Holds"\nexit 1\n' > "$stub_suites/renamed-sessions.sh"
commit_all "failing assertion"
verify --base scenario-base >/dev/null 2>&1; failing_result=$?
check "FailingAssertionInASuite_FailsVerify because a failed suite must fail the run" \
  '[ "$failing_result" -eq 1 ] && [ "$(report_status)" = fail ] && [ "$(failed_checks)" = "tests flow" ]'
check "FailingAssertionInASuite_IsNamedInTheReport because the reader must know which suite failed" \
  'flow_summary | grep -q "flow: failed in renamed-sessions"'
exit "$((fails > 0))"
