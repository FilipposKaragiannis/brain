#!/bin/sh
# pr-without-pull-request.sh: how an item ends when its pr step opens no pull request, on the local
# adapter in a throwaway repo. A pr step done with no PR in its result and nothing on the task
# branch its base lacks leaves nothing for the owner to merge, so it raises no merge gate.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

NO_PULL_REQUEST_SUMMARY="No PR opened: the change had nothing to commit. Close the item."
pass_pr_step_with_no_pull_request() {
  "$local_adapter/write-state.sh" "$1" step=pr profile=bugfix
  start_step "$1"
  step_result "$1" pr "{\"status\":\"done\",\"summary\":\"$NO_PULL_REQUEST_SUMMARY\"}"
  finish_step "$1"
}

echo "pr without a pull request: nothing to merge raises no merge gate"
new_repo nothing-to-merge
sign_off="$("$local_adapter/create.sh" bug "Owner sign-off with no code" --size S --body "$body")"
pass_pr_step_with_no_pull_request "$sign_off"
check "PrStepWithNoPullRequestAndAnEmptyBranchDiff_RaisesNoMergeGate: there is no pull request to merge, so a merge gate would wait forever" \
  '[ "$(state "$sign_off" gate)" != merge ]'

if [ "$fails" -eq 0 ]; then echo "pr-without-pull-request: ok"; else echo "pr-without-pull-request: $fails failed"; exit 1; fi
