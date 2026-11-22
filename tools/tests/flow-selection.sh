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
printf 'exit 0\n' > "$suite/sessions.sh"
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
printf 'exit 1\n' > "$suite/sessions.sh"
expect 'SelectedSuiteFails_FailsVerification because a partial run must propagate failure' "$(result)" fail
git restore plugins/flow/tests/sessions.sh
mkdir -p plugins/flow/scripts
touch plugins/flow/scripts/verify.sh
expect 'VerifyImplementationChanges_RunItsIntegrationChecks because the shared inline fixture contains unrelated scenarios' "$(result)" pass
expect 'VerifyImplementationChanges_IncludeTheReportScenarios because standalone checks cover only part of verify' "$(grep -c '^flow: verify pass' "$work/output")" 1
git mv plugins/flow/tests/sessions.sh plugins/flow/tests/renamed.sh
expect 'RemovedSuite_RunsFullCoverage because its old path has no runnable suite' "$(result)" fail
expect 'FullCoverage_IncludesJiraContract because each backend has its own contract run' "$(grep -c '^flow: contract-jira FAIL' "$work/output")" 1
base=unavailable
expect 'MissingBase_RunsFullCoverage because the changed inputs cannot be determined' "$(result)" fail
