#!/bin/sh
# verify-flow-runner.sh: verify on the local adapter in throwaway repos. A check's output reaches
# the verify log while the check still runs. The flow entry of .standards/config.json runs this
# checkout's suite runner on stub suites: a change to one suite runs that suite alone and its lines
# reach the log under its name; a new folder, an unresolved base (also beside a ref named
# unavailable), a renamed suite and a deleted suite each run every suite; one lane runs one suite
# at a time and three lanes overlap them; a failing assertion fails verify and the report names
# its suite; a run stopped at verify.limit shows the suite it was in and that suite's last check.
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

log_wait_seconds=60; slow_check_poll_seconds=0.2; lane_hold_seconds=1
new_item streaming ""
standards_with_test slow "printf '%s-%s\\n' started slow-check; while [ ! -f '$work/release-slow' ] && [ -d '$work' ]; do sleep $slow_check_poll_seconds; done"
verify >/dev/null 2>&1 &
streaming_verify=$!
until_true "$log_wait_seconds" 'grep -q started-slow-check "$reports/verify.log"'; seen_while_running=$?
: > "$work/release-slow"
wait "$streaming_verify"
check "CheckStillRunning_HasItsOutputInTheLog because a run stopped at its limit must show where it stood" \
  '[ "$seen_while_running" -eq 0 ]'

marketplace="$plugin/../.."
# stub_marketplace: commits this checkout's runner, tools/test.sh, the flow entry of its config and
# _base_fixture.sh to the worktree, with passing stub suites; sets stub_suites.
stub_marketplace() {
  stub_suites="$worktree/plugins/flow/tests"
  mkdir -p "$worktree/tools/lib" "$worktree/.standards" "$stub_suites"
  cp "$marketplace/tools/lib/flow_suites.py" "$worktree/tools/lib/"
  cp "$marketplace/tools/test.sh" "$worktree/tools/"
  cp "$here/_base_fixture.sh" "$stub_suites/"
  python3 -c 'import json,sys; flow=[entry for entry in json.load(open(sys.argv[1]))["test"] if entry["name"]=="flow"]; json.dump({"test": flow}, open(sys.argv[2], "w"))' \
    "$marketplace/.standards/config.json" "$worktree/.standards/config.json"
  for stub in run adapter-contract sessions holds base-claim base-readers; do printf 'echo "  ok   Stub_Holds"\n' > "$stub_suites/$stub.sh"; done
  git -C "$worktree" add tools .standards plugins && git -C "$worktree" commit -qm "stub marketplace"
}
new_item runner ""
stub_marketplace
# base_here: the next change is compared with the worktree's HEAD, through the scenario-base branch.
base_here() { git -C "$worktree" branch -f scenario-base HEAD; }
# commit_all <message>: commits every change under plugins/flow in the worktree.
commit_all() { git -C "$worktree" add -A plugins && git -C "$worktree" commit -qm "$1"; }
flow_status() { python3 -c 'import json,sys; print([check["status"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]=="tests flow"][0])' "$reports/verify.json"; }
flow_summary() { python3 -c 'import json,sys; print([check["summary"] for check in json.load(open(sys.argv[1]))["checks"] if check["name"]=="tests flow"][0])' "$reports/verify.json"; }
# suites_passed: the suites the log shows as passed, sorted on one line.
suites_passed() { sed -n 's/^flow: \(.*\) pass ([0-9.]*s)$/\1/p' "$reports/verify.log" | sort | tr '\n' ' '; }
# every_suite_ran: the flow check passed and the log shows exactly the suites in expected_suites,
# the whole set for the stub marketplace's files at that point.
every_suite_ran() { [ "$(flow_status)" = pass ] && [ "$(suites_passed)" = "$expected_suites " ]; }
expected_suites="base-claim base-readers contract-github contract-jira contract-local holds inline sessions"

base_here
printf 'echo "  ok   Stub_StillHolds"\n' >> "$stub_suites/sessions.sh"
commit_all "sessions"
verify --base scenario-base >/dev/null 2>&1; one_suite_result=$?
check "OneChangedSuite_RunsAloneThroughVerify because the runner narrows a change to the suite it names" \
  '[ "$one_suite_result" -eq 0 ] && grep -qx "flow: selected sessions" "$reports/verify.log"'
check "PassingSuite_HasItsLinesInTheLogUnderItsName because a pass needs its evidence" \
  'grep -qx "\[sessions\]   ok   Stub_StillHolds" "$reports/verify.log"'

verify --base no-such-base >/dev/null 2>&1
check "UnresolvedBaseAfterANarrowPass_RunsEverySuite because the narrow pass proved only the suite it ran" 'every_suite_ran'

base_here
mkdir -p "$worktree/plugins/flow/new-runtime" && echo 'exit 0' > "$worktree/plugins/flow/new-runtime/check.sh"
commit_all "new folder"
verify --base scenario-base >/dev/null 2>&1
check "FileInANewFlowFolder_RunsEverySuite because verify must not skip what no path names" 'every_suite_ran'

git -C "$worktree" tag unavailable HEAD
verify --base no-such-base >/dev/null 2>&1
check "UnresolvedBase_RunsEverySuite because the change set is unknown" 'every_suite_ran'
check "UnresolvedBase_SaysTheBaseIsUnavailable because a full run must say why it ran" \
  'grep -q "no comparison base available" "$reports/verify.log"'

base_here
git -C "$worktree" mv plugins/flow/tests/sessions.sh plugins/flow/tests/renamed-sessions.sh
commit_all "rename"
expected_suites="base-claim base-readers contract-github contract-jira contract-local holds inline renamed-sessions"
verify --base scenario-base >/dev/null 2>&1
check "RenamedSuite_RunsEverySuite because the old path names no suite" 'every_suite_ran'

base_here
git -C "$worktree" rm -q plugins/flow/tests/holds.sh
commit_all "delete"
expected_suites="base-claim base-readers contract-github contract-jira contract-local inline renamed-sessions"
verify --base scenario-base >/dev/null 2>&1
check "DeletedSuite_RunsEverySuite because what it covered is unknown" 'every_suite_ran'

# lanes_overlapped: whether two stub suites held a lane at once in the last run.
lanes_overlapped() { if [ -f "$work/overlaps" ]; then echo overlapped; else echo alone; fi; }
mkdir "$work/holders"
for stub in "$stub_suites"/[!_]*.sh; do
  cat > "$stub" <<STUB
: > "$work/holders/\$\$"
[ "\$(ls "$work/holders" | wc -l | tr -d ' ')" -eq 1 ] || echo overlap >> "$work/overlaps"
sleep $lane_hold_seconds
rm "$work/holders/\$\$"
STUB
done
commit_all "lane stubs"
# run_with_lanes <count>: a fresh full run through verify with that many lanes.
run_with_lanes() { rm -f "$work/overlaps"; (FLOW_SUITE_LANES="$1"; export FLOW_SUITE_LANES; verify --fresh --base no-such-base >/dev/null 2>&1); }
run_with_lanes 1
check "LaneCount1_RunsEverySuite because any whole count from 1 must work" 'every_suite_ran'
check "LaneCount1_RunsOneSuiteAtATime because a single lane never starts a second suite" '[ "$(lanes_overlapped)" = alone ]'
run_with_lanes 3
check "LaneCount3_RunsEverySuite because any whole count from 1 must work" 'every_suite_ran'
check "LaneCount3_RunsSuitesSideBySide because the lanes exist to overlap suites" '[ "$(lanes_overlapped)" = overlapped ]'
(FLOW_SUITE_LANES=0; export FLOW_SUITE_LANES; verify --fresh --base no-such-base >/dev/null 2>&1)
zero_lanes_named="FLOW_SUITE_LANES.*'0'"
check "LaneCountZero_FailsTheFlowCheck because the variable reaches the runner through verify" \
  '[ "$(flow_status)" = fail ] && flow_summary | grep -q "$zero_lanes_named"'

base_here
printf '%s\n' '. "$(dirname "$0")/_base_fixture.sh"' 'check "StubAssertion_Holds because a real suite fails this way" false' 'rm -rf "$work"' 'exit "$((fails > 0))"' > "$stub_suites/renamed-sessions.sh"
commit_all "failing assertion"
verify --base scenario-base >/dev/null 2>&1; failing_result=$?
check "FailingAssertionInASuite_FailsVerify because a failed suite must fail the run" \
  '[ "$failing_result" -eq 1 ] && [ "$(report_status)" = fail ] && [ "$(failed_checks)" = "tests flow" ]'
check "FailingAssertionInASuite_IsNamedInTheReport because the reader must know which suite failed" \
  'flow_summary | grep -q "flow: failed in renamed-sessions"'

limit_yaml="verify:
  limit: 5s
"
new_item limited ""
limit_yaml=""
stub_marketplace
base_here
printf 'echo "  ok   Stub_FirstCheckHolds"\nwhile [ -d "%s" ]; do sleep %s; done\n' "$work" "$slow_check_poll_seconds" > "$stub_suites/sessions.sh"
commit_all "a suite that never ends"
verify --start --base scenario-base >/dev/null 2>&1
wait_until_ended
check "RunStoppedAtTheLimit_NamesTheActiveSuite because the owner must see which suite stalled" \
  'grep -qx "flow: sessions stopped" "$reports/verify.log"'
check "RunStoppedAtTheLimit_ShowsTheActiveSuitesLastCheck because that is where the run stood" \
  'grep -qx "\[sessions\]   ok   Stub_FirstCheckHolds" "$reports/verify.log"'
exit "$((fails > 0))"
