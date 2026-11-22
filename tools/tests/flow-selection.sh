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
mkdir -p plugins/flow/new-runtime
touch plugins/flow/new-runtime/check.sh
expect 'FileInANewFolder_RunsFullCoverage because the runner cannot know which suites read it' "$(result)" fail
expect 'FullCoverageForANewFolder_IncludesJiraContract because every suite runs' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
rm -r plugins/flow/new-runtime
mkdir -p plugins/flow/scripts
touch plugins/flow/scripts/verify.sh
expect 'VerifyImplementationChanges_RunItsIntegrationChecks because the shared inline fixture contains unrelated scenarios' "$(result)" pass
expect 'VerifyImplementationChanges_IncludeTheReportScenarios because standalone checks cover only part of verify' "$(grep -c '^flow: verify pass' "$work/output")" 1
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
unset FLOW_SUITE_LANES
