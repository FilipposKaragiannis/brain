#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tools="$root/tools"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

. "$here/_flow_project_fixture.sh"
suite_outcomes() { grep -E '^flow: [^ ]+ (pass|FAIL) \(' "$work/output" | cut -d ' ' -f 2,3 | sort | tr '\n' ' ' | sed 's/ $//'; }

echo 'exit 0' >> "$suite/sessions.sh"
writes_bytecode() {
  writes_probe="$(mktemp -d "$work/probe.XXXXXX")"; printf 'probed = 1\n' > "$writes_probe/probe.py"
  "$1" -I -c 'import sys; sys.path.append(sys.argv[1]); import probe' "$writes_probe" 2>/dev/null || true
  if [ -d "$writes_probe/__pycache__" ]; then rm -r "$writes_probe"; return 0; fi
  rm -r "$writes_probe"; return 1
}
bytecode_writer=""
for candidate in "$(command -v python3)" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -x "$candidate" ] && writes_bytecode "$candidate"; then bytecode_writer="$candidate"; break; fi
done
if [ -n "$bytecode_writer" ]; then
  mkdir "$work/bytecode-writer"; ln -s "$bytecode_writer" "$work/bytecode-writer/python3"
  writer_result="$(PATH="$work/bytecode-writer:$PATH" && result)"
  expect "OneChangedSuiteUnderAPythonThatWritesBytecode_Passes because $bytecode_writer runs the runner like any python3" "$writer_result" pass
  expect "OneChangedSuiteUnderAPythonThatWritesBytecode_RunsAlone because the runner's own modules are no change" "$(head -1 "$work/output")" 'flow: selected sessions'
  expect 'RunUnderAPythonThatWritesBytecode_LeavesNoUntrackedFile because the runner never writes into the project it tests' "$(git status --porcelain --untracked-files=all | grep -c '^??' || true)" 0
  rm -r "$work/bytecode-writer"
else
  echo 'skip OneChangedSuiteUnderAPythonThatWritesBytecode: no python3 here writes bytecode under -I'
fi
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
git tag -d unavailable > /dev/null
suite_names() { grep -E '^flow: [^ ]+ (pass|FAIL) \(' "$work/output" | cut -d ' ' -f 2 | sort; }
run_shards() {
  : > "$work/shard-suites"; shard=1
  while [ "$shard" -le "$1" ]; do
    python3 -I tools/lib/flow_suites.py all --shard "$shard/$1" > "$work/output" 2>&1 || true
    suite_names >> "$work/shard-suites"; shard=$((shard + 1))
  done
}
printf 'exit 0\n' > "$suite/unmeasured.sh"
python3 -I tools/lib/flow_suites.py all > "$work/output" 2>&1 || true
every_suite="$(suite_names)"
for count in 1 2 3 4 12; do
  run_shards "$count"
  expect "ShardsOf${count}_TogetherRunEverySuite because a suite left out of every shard never runs in CI" "$(sort -u "$work/shard-suites")" "$every_suite"
  expect "ShardsOf${count}_RunNoSuiteTwice because shards must not overlap" "$(sort "$work/shard-suites" | uniq -d)" ''
  expect "ShardsOf${count}_RunTheUnmeasuredSuiteOnce because a suite missing from the table still belongs to exactly one shard" "$(grep -cx unmeasured "$work/shard-suites")" 1
done
rm "$suite/unmeasured.sh"
longest_suite="$(printf '%s\n' "$every_suite" | tail -1)"
printf '%s\n' "$every_suite" | python3 -I -c 'import json, sys; json.dump({name: 100 if name == sys.argv[2] else 1 for name in sys.stdin.read().split()}, open(sys.argv[1], "w"))' tools/lib/flow_suite_durations.json "$longest_suite"
python3 -I tools/lib/flow_suites.py all --shard 1/2 > "$work/output" 2>&1 || true
expect 'SuiteLongerThanTheRestTogether_RunsInAShardOfItsOwn because shards are balanced by measured time' "$(suite_names | tr '\n' ' ')" "$longest_suite "
git restore tools/lib/flow_suite_durations.json
shard_suites() { python3 -I tools/lib/flow_suites.py all --shard "$1" > "$work/output" 2>&1 || true; suite_names | tr '\n' ' '; }
expect 'ShardRunTwice_RunsTheSameSuites because a job that is retried must run what it ran before' "$(shard_suites 2/4)" "$(shard_suites 2/4)"
printf '%s\n' "$every_suite" | python3 -I -c 'import json, sys; json.dump({name: 7 for name in sys.stdin.read().split()}, open(sys.argv[1], "w"))' tools/lib/flow_suite_durations.json
suites_in_shard() { shard_suites "$1" | wc -w | tr -d ' '; }
uneven_by_more_than_one() { [ "$(( $(suites_in_shard 1/3) - $(suites_in_shard 3/3) ))" -le 1 ] && echo no || echo yes; }
expect 'SuitesOfEqualDuration_SplitIntoShardsWithinOneSuite because no shard may carry more than its share' "$(uneven_by_more_than_one)" no
git restore tools/lib/flow_suite_durations.json
for bad in 0/4 5/4 4 a/4 1/0 ''; do
  label="$(printf '%s' "${bad:-Empty}" | sed 's#/#Of#')"
  if python3 -I tools/lib/flow_suites.py all --shard "$bad" > "$work/output" 2>&1; then outcome=pass; else outcome=fail; fi
  expect "Shard${label}_Fails because only <number>/<count> with the number from 1 to the count names a shard" "$outcome" fail
  expect "Shard${label}_RunsNoSuite because a usage error comes before any suite starts" "$(suites_reported)" 0
done
