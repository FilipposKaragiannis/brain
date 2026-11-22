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
printf 'test "$1" = verify\n' > "$suite/run.sh"
for name in base-claim base-readers verify-scope; do printf 'exit 0\n' > "$suite/$name.sh"; done
printf 'test "$1" != jira\n' > "$suite/adapter-contract.sh"
git add .
git commit -qm baseline
base="$(git rev-parse HEAD)"

result() { if "$project/tools/test.sh" flow-since "$base" > "$work/output" 2>&1; then echo pass; else echo fail; fi; }
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; cat "$work/output"; exit 1; }; echo "ok $1"; }

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
git restore plugins/flow/tests/sessions.sh
expect 'OnlyTheChangelogChanged_SelectsNothing because release notes are no test input' "$(result)" pass
expect 'NothingSelected_SaysSo because a verifier must see that no suite ran' "$(head -1 "$work/output")" 'flow: no Flow test inputs changed'
touch plugins/flow/README.md
expect 'OnlyAReadmeChanged_SelectsNothing because plain docs are no test input' "$(result)" pass
expect 'ReadmeOnly_SaysNothingRan because a verifier must see that no suite ran' "$(head -1 "$work/output")" 'flow: no Flow test inputs changed'
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
expect 'VerifyImplementationChanges_RunItsIntegrationChecks because the shared inline fixture contains unrelated scenarios' "$(result)" pass
expect 'VerifyImplementationChanges_IncludeTheReportScenarios because standalone checks cover only part of verify' "$(grep -c '^flow: verify pass' "$work/output")" 1
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
git mv plugins/flow/tests/sessions.sh plugins/flow/tests/renamed.sh
expect 'RemovedSuite_RunsFullCoverage because its old path has no runnable suite' "$(result)" fail
expect 'FullCoverage_IncludesJiraContract because each backend has its own contract run' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
base=unavailable
expect 'MissingBase_RunsFullCoverage because the changed inputs cannot be determined' "$(result)" fail
expect 'FailedRun_NamesItsFailedSuitesLast because a verify summary keeps only the last lines' "$(tail -1 "$work/output")" 'flow: failed in contract-jira, inline'
for stub in "$suite"/*.sh; do
  printf 'if mkdir "%s/lane" 2>/dev/null; then sleep 1; rmdir "%s/lane"; else echo overlap >> "%s/overlaps"; fi\n' "$work" "$work" "$work" > "$stub"
done
overlapped() { if [ -f "$work/overlaps" ]; then echo overlapped; else echo alone; fi; }
export FLOW_SUITE_LANES=1
expect 'OneLane_Passes because one lane is a valid count' "$(result)" pass
expect 'OneLane_RunsOneSuiteAtATime because a single lane never starts a second suite' "$(overlapped)" alone
FLOW_SUITE_LANES=3
expect 'ThreeLanes_Pass because the default count must work when named' "$(result)" pass
expect 'ThreeLanes_RunSuitesSideBySide because the lanes exist to overlap suites' "$(overlapped)" overlapped
FLOW_SUITE_LANES=0
expect 'ZeroLanes_Fails because no suite could ever run' "$(result)" fail
expect 'ZeroLanes_SaysWhy because the owner must see the bad value' "$(tail -1 "$work/output")" "flow: FLOW_SUITE_LANES takes a whole number from 1, not '0'"
for bad in abc -1 ''; do
  FLOW_SUITE_LANES="$bad"
  expect "LaneCount${bad:-Empty}_Fails because only a whole number from 1 is a lane count" "$(result)" fail
  expect "LaneCount${bad:-Empty}_SaysWhy because the owner must see the bad value" "$(tail -1 "$work/output")" "flow: FLOW_SUITE_LANES takes a whole number from 1, not '$bad'"
done
unset FLOW_SUITE_LANES
rm -f "$work/overlaps"
expect 'NoLaneVariable_Passes because the default must work' "$(result)" pass
expect 'NoLaneVariable_RunsThreeSuitesAtOnce because the default is three lanes' "$(overlapped)" overlapped
