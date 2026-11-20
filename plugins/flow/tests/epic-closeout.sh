#!/bin/sh
# epic-closeout.sh: how an epic ends, on the local adapter in throwaway repos with a fake gh. A
# closeout that passed opens the pull request from the epic branch into the branch the epic
# started from, records it on the epic and raises the merge gate; the sweep closes the epic once
# that PR is merged. An epic with no epic branch, or with nothing on it its base lacks, is closed
# with no PR. An open PR from the epic branch is taken as it is. A PR gh cannot open leaves the
# epic open at closeout behind an escalation gate.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

export FAKE_GH_DIR="$work/gh"
mkdir -p "$FAKE_GH_DIR" "$work/github" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$plugin/tests/fake-gh.sh" "$work/github/gh"
PATH="$work/github:$PATH"; export PATH

CLOSEOUT_SUMMARY="Every acceptance line is proven."
# github_repo <dir>: a fresh repository (new_repo) whose PRs live on a GitHub the fake gh plays,
# with no pull request yet.
github_repo() {
  new_repo "$1"
  printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
  printf '{"issues": []}' > "$FAKE_GH_DIR/issues.json"; rm -f "$FAKE_GH_DIR/fail"
}
# pull_request <field>: a field of the one pull request the fake GitHub holds, or nothing.
pull_request() { python3 -c 'import json, sys; print((json.load(open(sys.argv[1])).get("pr") or {}).get(sys.argv[2], ""))' "$FAKE_GH_DIR/issues.json" "$1"; }
# set_pull_request <json>: the pull request the fake GitHub holds.
set_pull_request() { python3 -c 'import json, sys; data = json.load(open(sys.argv[1])); data["pr"] = json.loads(sys.argv[2]); json.dump(data, open(sys.argv[1], "w"))' "$FAKE_GH_DIR/issues.json" "$1"; }
# merge_pull_request: the owner merged the pull request on GitHub.
merge_pull_request() { python3 -c 'import json, sys; data = json.load(open(sys.argv[1])); data["pr"]["state"] = "MERGED"; json.dump(data, open(sys.argv[1], "w"))' "$FAKE_GH_DIR/issues.json"; }
item_status() { "$local_adapter/read.sh" "$1" | json_value status; }
# epic_with_work <title>: an epic whose epic branch holds a commit the default branch lacks; prints the epic.
epic_with_work() {
  worked_epic="$("$local_adapter/create.sh" epic "$1" --body x)"
  remote_branch "$(epic_of "$worked_epic")"; remote_commit "$(epic_of "$worked_epic")" "$(slug "$worked_epic").txt"
  printf '%s' "$worked_epic"
}
# pass_closeout <epic>: the epic's closeout step ran and passed; the exit code is advance.sh's.
pass_closeout() {
  "$local_adapter/write-state.sh" "$1" step=closeout profile=epic
  start_step "$1"
  step_result "$1" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
  finish_step "$1"
}

echo "epic closeout: a passed closeout opens the epic's pull request"
github_repo merging
epic="$(epic_with_work "Playoffs")"
pass_closeout "$epic"
check "EpicCloseoutWithWorkOnItsBranch_OpensAPullRequestFromTheEpicBranch: the epic's work reaches its base through one PR" \
  '[ "$(pull_request headRefName)" = "$(epic_of "$epic")" ]'
check "EpicCloseoutWithWorkOnItsBranch_AimsThePullRequestAtTheConfigBase: an epic with no epic above it started from the default branch" \
  '[ "$(pull_request baseRefName)" = main ]'
check "EpicCloseoutWithWorkOnItsBranch_PutsTheCloseoutSummaryInThePullRequest: the owner reads what the closeout proved where they merge" \
  'pull_request body | grep -qF "$CLOSEOUT_SUMMARY"'
check "EpicCloseoutWithWorkOnItsBranch_RecordsThePullRequestOnTheEpic: the sweep and the console find the PR from the epic" \
  '[ -n "$(pull_request url)" ] && [ "$(state "$epic" pr)" = "$(pull_request url)" ]'
check "EpicCloseoutWithWorkOnItsBranch_WaitsAtTheMergeGate: the merge is the owner's" \
  '[ "$(state "$epic" gate)" = merge ]'
check "EpicCloseoutWithWorkOnItsBranch_LeavesTheEpicOpen: its work is not on the base yet" \
  '[ "$(item_status "$epic")" = open ]'

echo "epic closeout: the merge closes the epic"
"$plugin/scripts/steward.sh" sweep --dry-run > "$work/sweep-open.out" 2>&1
check "EpicWhosePullRequestIsStillOpen_StaysAtTheMergeGate: an open PR is no answer" \
  '[ "$(state "$epic" gate)" = merge ] && ! grep -qF "$epic" "$work/sweep-open.out"'
merge_pull_request
"$plugin/scripts/steward.sh" sweep --dry-run > "$work/sweep-dry.out" 2>&1
check "SweepDryRunOfAMergedEpicPullRequest_ClosesNothing: a dry run only says what it would do" \
  '[ "$(item_status "$epic")" = open ] && grep -qF "$epic: would close it" "$work/sweep-dry.out"'
"$plugin/scripts/steward.sh" sweep > "$work/sweep.out" 2>&1
check "EpicWhosePullRequestMerged_IsClosedByTheSweep: the merge is the owner's answer, so nobody closes the epic by hand" \
  '[ "$(item_status "$epic")" = closed ]'
check "EpicWhosePullRequestMerged_HasNoGateLeft: a closed item must not keep a gate waiting" \
  '[ "$(state "$epic" gate)" = none ]'

echo "epic closeout: an epic with nothing to merge is closed"
github_repo nothing
branchless="$("$local_adapter/create.sh" epic "Friendlies" --body x)"
pass_closeout "$branchless"
check "EpicCloseoutWithNoEpicBranch_ClosesTheEpic: its tasks merged into the base one by one, so nothing is left to merge" \
  '[ "$(item_status "$branchless")" = closed ]'
check "EpicCloseoutWithNoEpicBranch_OpensNoPullRequest: there is no branch to open one from" \
  '[ -z "$(pull_request url)" ]'
level="$("$local_adapter/create.sh" epic "Cup" --body x)"
remote_branch "$(epic_of "$level")"
pass_closeout "$level"
check "EpicCloseoutWhoseBranchHoldsNothingItsBaseLacks_ClosesTheEpic: GitHub refuses a PR with no commits, and nothing is left to merge" \
  '[ "$(item_status "$level")" = closed ] && [ -z "$(pull_request url)" ]'

echo "epic closeout: an open pull request from the epic branch is taken as it is"
github_repo taken
owned="$(epic_with_work "Transfers")"
set_pull_request "{\"number\": 77, \"state\": \"OPEN\", \"url\": \"https://gh/pull/77\", \"headRefName\": \"$(epic_of "$owned")\", \"baseRefName\": \"main\"}"
pass_closeout "$owned"
check "EpicCloseoutWithAnOpenPullRequestFromItsBranch_RecordsThatOne: the owner's PR is not doubled" \
  '[ "$(state "$owned" pr)" = https://gh/pull/77 ] && [ "$(pull_request number)" = 77 ]'

echo "epic closeout: an epic under an epic merges into that epic's branch"
github_repo nested
outer="$("$local_adapter/create.sh" epic "Season" --body x)"
remote_branch "$(epic_of "$outer")"
inner="$("$local_adapter/create.sh" epic "Final" --body x --parent "$outer")"
git -C "$root/other" fetch -q origin && git -C "$root/other" push -q origin "origin/$(epic_of "$outer"):refs/heads/$(epic_of "$inner")"
remote_commit "$(epic_of "$inner")" final.txt
pass_closeout "$inner"
check "CloseoutOfAnEpicUnderAnEpicWithABranch_AimsThePullRequestAtThatBranch: the inner epic's work joins the outer epic, not the default branch" \
  '[ "$(pull_request baseRefName)" = "$(epic_of "$outer")" ]'

echo "epic closeout: a pull request gh cannot open is the owner's to open"
github_repo refused
stuck="$(epic_with_work "Awards")"
printf '9\nGitHub is down\n' > "$FAKE_GH_DIR/fail"
pass_closeout "$stuck"
check "EpicCloseoutWhosePullRequestCannotBeOpened_RaisesAnEscalationGate: the owner hears the closeout passed and the PR is missing" \
  '[ "$(state "$stuck" gate)" = escalation ]'
check "EpicCloseoutWhosePullRequestCannotBeOpened_NamesTheCommandInTheGate: the owner can open the PR without working out the branches" \
  'json_value message < ".flow/gates/$(slug "$stuck").json" | grep -qF -- "--head $(epic_of "$stuck")"'
check "EpicCloseoutWhosePullRequestCannotBeOpened_LeavesTheEpicOpenAtCloseout: clearing the gate runs the closeout again, which takes the PR the owner opened" \
  '[ "$(item_status "$stuck")" = open ] && [ "$(state "$stuck" step)" = closeout ]'

if [ "$fails" -eq 0 ]; then echo "epic-closeout: ok"; else echo "epic-closeout: $fails failed"; exit 1; fi
