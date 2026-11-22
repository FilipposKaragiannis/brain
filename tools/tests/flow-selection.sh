#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tools="$root/tools"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

project="$work/marketplace"
suite="$project/plugins/flow/tests"
mkdir -p "$project/tools/lib" "$project/.standards" "$suite"
cp "$tools/lib/flow_suites.py" "$project/tools/lib/"
cp "$tools/test.sh" "$project/tools/"
cp "$tools/../.standards/config.json" "$project/.standards/"
cd "$project"
git init -q -b main
git config user.email tests@example.test
git config user.name Tests
printf 'echo "  ok   StubCheck_Holds"\n' > "$suite/sessions.sh"
printf 'exit 1\n' > "$suite/run.sh"
for name in base-claim base-readers verify-scope verify-report; do printf 'exit 0\n' > "$suite/$name.sh"; done
printf 'test "$1" != jira\n' > "$suite/adapter-contract.sh"
git add .
git commit -qm baseline
base="$(git rev-parse HEAD)"

result() { if "$project/tools/test.sh" flow-since "$base" > "$work/output" 2>&1; then echo pass; else echo fail; fi; }
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; cat "$work/output"; exit 1; }; echo "ok $1"; }
suites_reported() { grep -cE '^flow: [^ ]+ (pass|FAIL) \(' "$work/output"; }
suite_outcomes() { grep -E '^flow: [^ ]+ (pass|FAIL) \(' "$work/output" | cut -d ' ' -f 2,3 | sort | tr '\n' ' ' | sed 's/ $//'; }
lane_hold_seconds=1; poll_seconds=0.1; wait_ticks=50; hang_ticks=300; child_seconds=120

echo 'exit 0' >> "$suite/sessions.sh"
mkdir -p plugins/flow/changelog.d
echo release > plugins/flow/changelog.d/release.md
expect 'OneChangedSuite_RunsAlone because an unrelated failing adapter cannot affect it' "$(result)" pass
expect 'SelectedSuite_IsReported because the verifier needs to show what ran' "$(head -1 "$work/output")" 'flow: selected sessions'
expect 'PassingSuite_PrintsItsLinesWithItsName because a pass needs its evidence' "$(grep -c '^\[sessions\]   ok   StubCheck_Holds$' "$work/output")" 1
expect 'PassingSuite_KeepsItsSummaryLine because the verifier reads the outcome per suite' "$(grep -c '^flow: sessions pass ([0-9.]*s)$' "$work/output")" 1
printf 'echo "  FAIL StubCheck_Holds"\nexit 1\n' > "$suite/sessions.sh"
expect 'SelectedSuiteFails_FailsVerification because a partial run must propagate failure' "$(result)" fail
expect 'FailingSuite_PrintsItsLinesWithItsName because the failure must name its suite' "$(grep -c '^\[sessions\]   FAIL StubCheck_Holds$' "$work/output")" 1
cat > "$suite/sessions.sh" <<STUB
echo "  ok   Stub_FirstCheckHolds"
sleep $child_seconds &
echo \$! > "$work/child"
ticks=0
while [ "\$ticks" -lt $hang_ticks ]; do echo tick >> "$work/ticks"; sleep $poll_seconds; ticks=\$((ticks + 1)); done
STUB
python3 -I "$project/tools/lib/flow_suites.py" since "$base" > "$work/output" 2>&1 &
runner=$!
ticks=0; until [ -f "$work/ticks" ] || [ "$ticks" -ge "$wait_ticks" ]; do sleep "$poll_seconds"; ticks=$((ticks + 1)); done
kill -TERM "$runner"
ticks=0; while kill -0 "$runner" 2>/dev/null && [ "$ticks" -lt "$wait_ticks" ]; do sleep "$poll_seconds"; ticks=$((ticks + 1)); done
if kill -0 "$runner" 2>/dev/null; then runner_state=running; else runner_state=ended; fi
ticks_at_stop="$(wc -l < "$work/ticks")"; sleep "$lane_hold_seconds"
wait "$runner" || true
suite_child="$(cat "$work/child")"
if kill -0 "$suite_child" 2>/dev/null; then child_state=running; kill "$suite_child"; else child_state=ended; fi
expect 'RunnerGivenTerm_EndsWhileItsSuiteHangs because a hung suite must not block cancellation' "$runner_state" ended
expect 'RunnerGivenTerm_StopsItsRunningSuite because a stopped run leaves no suite behind' "$(wc -l < "$work/ticks")" "$ticks_at_stop"
expect 'RunnerGivenTerm_EndsTheChildCommandsOfItsSuite because a stopped run leaves no check behind' "$child_state" ended
expect 'RunnerGivenTerm_NamesTheStoppedSuite because the owner must see where the run stood' "$(grep -cx 'flow: sessions stopped' "$work/output")" 1
rm "$work/ticks" "$work/child"
git restore plugins/flow/tests/sessions.sh
expect 'OnlyTheChangelogChanged_SelectsNothing because release notes are no test input' "$(result)" pass
expect 'OnlyTheChangelogChanged_RunsNoSuite because release notes are no test input' "$(suites_reported)" 0
touch plugins/flow/README.md
expect 'OnlyAReadmeChanged_SelectsNothing because plain docs are no test input' "$(result)" pass
expect 'OnlyAReadmeChanged_RunsNoSuite because plain docs are no test input' "$(suites_reported)" 0
rm plugins/flow/README.md
for outside in shared/helper.sh tools/lib/helper.sh; do
  mkdir -p "$(dirname "$outside")"
  touch "$outside"
  expect "FileIn_$(dirname "$outside" | tr / -)_RunsFullCoverage because the runner knows no suite that reads it" "$(result)" fail
  expect "FullCoverageForFileIn_$(dirname "$outside" | tr / -)_IncludesJiraContract because every suite runs" "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
  rm "$outside"
done
mkdir -p plugins/flow/new-runtime
touch plugins/flow/new-runtime/check.sh
expect 'FileInANewFolder_RunsFullCoverage because the runner cannot know which suites read it' "$(result)" fail
expect 'FullCoverageForANewFolder_IncludesJiraContract because every suite runs' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
rm -r plugins/flow/new-runtime
mkdir -p plugins/flow/scripts
touch plugins/flow/scripts/verify.sh
expect 'VerifyImplementationChanges_Pass because every suite that runs verify passes' "$(result)" pass
expect 'VerifyImplementationChanges_LeaveOutUnrelatedSuites because only the suites that run verify can be affected' "$(grep -c '^flow: contract-jira ' "$work/output")" 0
expect 'VerifyImplementationChanges_RunEverySuiteThatRunsVerify because a suite left out would hide a broken verify' "$(suite_outcomes)" 'base-claim pass base-readers pass verify-report pass verify-scope pass'
expect 'VerifyImplementationChanges_IncludeTheReportScenarios because standalone checks cover only part of verify' "$(grep -c '^flow: verify-report pass' "$work/output")" 1
rm plugins/flow/scripts/verify.sh
cat > "$suite/sessions.sh" <<'STUB'
echo first
echo
printf '%s\n' 'literal %s and backslash \n'
echo 'to the error stream' >&2
printf unterminated
STUB
expect 'SuiteWithAwkwardOutput_Passes because only its exit code decides' "$(result)" pass
expect 'BlankLine_KeepsItsPrefix because every line must name its suite' "$(grep -cFx '[sessions] ' "$work/output")" 1
expect 'ErrorStreamLine_KeepsItsPrefix because a failure often prints only there' "$(grep -cFx '[sessions] to the error stream' "$work/output")" 1
expect 'FormatCharactersAndBackslashes_PrintVerbatim because output is data' "$(grep -cFx '[sessions] literal %s and backslash \n' "$work/output")" 1
expect 'LastLineWithoutNewline_IsPrefixedAndEnded because its text must not run into the next line' "$(grep -cFx '[sessions] unterminated' "$work/output")" 1
expect 'EveryOutputLine_CarriesAPrefix because a bare line would hide which suite wrote it' "$(grep -v -e '^\[sessions\] ' -e '^flow: ' "$work/output" | wc -l | tr -d ' ')" 0
git restore plugins/flow/tests/sessions.sh
git rm -q plugins/flow/tests/base-readers.sh
expect 'DeletedSuite_RunsFullCoverage because what it covered is unknown' "$(result)" fail
expect 'DeletedSuite_IncludesJiraContract because every suite still runs' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
expect 'DeletedSuite_IsNotRun because its file is gone' "$(grep -c '^flow: base-readers ' "$work/output")" 0
git restore --staged --worktree plugins/flow/tests/base-readers.sh
git rm -q plugins/flow/tests/adapter-contract.sh
result > /dev/null
expect 'DeletedContractSuite_RunsTheRemainingSuites because what it covered is unknown' "$(grep -c '^flow: sessions pass' "$work/output")" 1
git restore --staged --worktree plugins/flow/tests/adapter-contract.sh
git mv plugins/flow/tests/sessions.sh plugins/flow/tests/renamed.sh
expect 'RemovedSuite_RunsFullCoverage because its old path has no runnable suite' "$(result)" fail
expect 'FullCoverage_IncludesJiraContract because each backend has its own contract run' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
base=unavailable
printf 'exit 1\n' > "$suite/verify-scope.sh"
expect 'MissingBase_RunsFullCoverage because the changed inputs cannot be determined' "$(result)" fail
expect 'FailedRun_NamesItsFailedSuitesLast because a verify summary keeps only the last lines' "$(tail -1 "$work/output")" 'flow: failed in contract-jira, verify-scope'
printf 'exit 0\n' > "$suite/verify-scope.sh"
git mv plugins/flow/tests/renamed.sh plugins/flow/tests/sessions.sh
git tag unavailable HEAD
expect 'MissingBaseWithARefOfThatName_RunsFullCoverage because a ref can take any name' "$(result)" fail
expect 'MissingBaseWithARefOfThatName_IncludesJiraContract because every suite runs' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
mkdir "$work/holders"
for stub in "$suite"/*.sh; do
  cat > "$stub" <<STUB
: > "$work/holders/\$\$"
ls "$work/holders" | wc -l | tr -d ' ' >> "$work/holder-counts"
sleep $lane_hold_seconds
rm "$work/holders/\$\$"
STUB
done
most_suites_at_once() { sort -n "$work/holder-counts" | tail -1; rm "$work/holder-counts"; }
export FLOW_SUITE_LANES=1
expect 'OneLane_Passes because one lane is a valid count' "$(result)" pass
expect 'OneLane_RunsOneSuiteAtATime because a single lane never starts a second suite' "$(most_suites_at_once)" 1
FLOW_SUITE_LANES=3
expect 'ThreeLanes_Pass because the default count must work when named' "$(result)" pass
expect 'ThreeLanes_RunThreeSuitesAtOnce because each lane holds one suite' "$(most_suites_at_once)" 3
FLOW_SUITE_LANES=0
expect 'ZeroLanes_Fails because no suite could ever run' "$(result)" fail
expect 'ZeroLanes_NamesTheVariableAndTheValue because the owner must see what to fix' "$(tail -1 "$work/output" | grep -c "FLOW_SUITE_LANES.*'0'")" 1
for bad in abc -1 ''; do
  FLOW_SUITE_LANES="$bad"
  expect "LaneCount${bad:-Empty}_Fails because only a whole number from 1 is a lane count" "$(result)" fail
  expect "LaneCount${bad:-Empty}_NamesTheVariableAndTheValue because the owner must see what to fix" "$(tail -1 "$work/output" | grep -c -e "FLOW_SUITE_LANES.*'$bad'")" 1
done
unset FLOW_SUITE_LANES
rm -f "$work/holder-counts"
expect 'NoLaneVariable_Passes because the default must work' "$(result)" pass
expect 'NoLaneVariable_RunsThreeSuitesAtOnce because the default is three lanes' "$(most_suites_at_once)" 3
cp -p "$root/plugins/flow/tests/run.sh" "$suite/run.sh"
if "$project/tools/test.sh" flow > "$work/output" 2>&1; then whole_part=pass; else whole_part=fail; fi
expect 'FlowPart_Passes because CI runs the whole Flow part through it' "$whole_part" pass
expect 'FlowPart_RunsEverySuite because a full run leaves none out' "$(suites_reported)" 8
if sh "$suite/run.sh" inline > "$work/output" 2>&1; then dispatcher_code=0; else dispatcher_code=$?; fi
expect 'FlowDispatcherGivenAnArgument_IsAUsageError because run.sh only hands the whole run to the runner' "$dispatcher_code" 2
