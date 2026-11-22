#!/bin/sh
# Tests the shape of .github/workflows/ci.yml that keeps CI honest: every job has a time limit, the
# one result job waits for every other job and fails on anything but success, every part of
# tools/test.sh is named so none can be skipped, and a newer push cancels only pull request runs.
# The result step is run here against sample job results. Exit 1 on any failure.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

workflow="$root/.github/workflows/ci.yml"
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; echo "  got:      $2"; echo "  expected: $3"; exit 1; }; echo "ok $1"; }

job_ids() { awk '/^jobs:/ { in_jobs = 1; next } in_jobs && /^  [a-z][a-z0-9-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$workflow"; }
job_lines() { awk -v job="$1" '/^jobs:/ { in_jobs = 1; next } in_jobs && /^  [a-z][a-z0-9-]*:$/ { current = $1; sub(/:$/, "", current) } in_jobs && current == job { print }' "$workflow"; }
jobs_without() { for job in $(job_ids); do job_lines "$job" | grep -q "$1" || echo "$job"; done | tr '\n' ' ' | sed 's/ $//'; }
result_needs() { job_lines result | sed -n 's/^    needs: \[\(.*\)\]$/\1/p' | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ' ' | sed 's/ $//'; }
other_jobs() { job_ids | grep -vx result | sort | tr '\n' ' ' | sed 's/ $//'; }
workflow_parts() { sed -n 's#^.*tools/test\.sh \(.*\)$#\1#p' "$workflow" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
every_part="$(sed -n 's/^every_part="\(.*\)"$/\1/p' "$root/tools/test.sh")"
parts_run_by_shards="$(printf '%s\n' "$every_part" | tr ' ' '\n' | grep -vx flow | sort | tr '\n' ' ' | sed 's/ $//')"

result_script="$work/result.sh"
job_lines result | awk '/^        run: \|$/ { copying = 1; next } copying { sub(/^          /, ""); print }' > "$result_script"
result_for() {
  needs="{\"lint\":{\"result\":\"success\"},\"flow\":{\"result\":\"$1\"}}"
  if RESULTS="$needs" sh "$result_script" > "$work/output" 2>&1; then echo pass; else echo fail; fi
}

expect 'EveryJob_HasATimeLimit because a hung suite once ran 73 minutes' "$(jobs_without '^    timeout-minutes: [0-9]')" ''
expect 'ResultJob_WaitsForEveryOtherJob because one required check must stand for them all' "$(result_needs)" "$(other_jobs)"
expect 'ResultJob_RunsWhenAJobFails because a skipped required check would pass' "$(job_lines result | grep -c '^    if: always()$')" 1
expect 'ResultStepGivenOnlySuccess_Passes because every job holds' "$(result_for success)" pass
expect 'ResultStepGivenAFailure_Fails because one failed job fails the run' "$(result_for failure)" fail
expect 'ResultStepGivenASkippedJob_Fails because a job that did not run proves nothing' "$(result_for skipped)" fail
expect 'ResultStepGivenACancelledJob_Fails because a job that did not finish proves nothing' "$(result_for cancelled)" fail
expect 'ResultStep_NamesEachJobWithItsResult because the owner must see which job broke' "$(result_for failure >/dev/null; grep -cx 'flow: failure' "$work/output")" 1
expect 'EveryPartButFlow_IsNamedOnTestShsCommandLine because an unnamed part is skipped when its tools are missing' "$(workflow_parts)" "$parts_run_by_shards"
expect 'TestShWithNoPartNamed_IsNeverRun because a whole run skips a part whose tools are missing' "$(grep -c 'tools/test\.sh *$' "$workflow" || true)" 0
expect 'FlowJob_RunsAShardOfTheSuites because the flow suites are split across jobs' "$(grep -c 'flow_suites\.py all --shard' "$workflow")" 1
expect 'FlowJob_TakesItsShardCountFromTheMatrix because adding a shard must not need a second edit' "$(grep -c 'FLOW_SHARD: .*matrix\.shard.*strategy\.job-total' "$workflow")" 1
expect 'PullRequestRuns_AreCancelledByANewerPush because their results are out of date' "$(grep -c "cancel-in-progress: .*github.event_name == 'pull_request'" "$workflow")" 1
expect 'RunsOnMain_HaveAGroupOfTheirOwn because a push to main must never cancel another' "$(grep -c 'group: .*github\.sha' "$workflow")" 1
