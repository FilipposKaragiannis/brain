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
github_repository() {
  new_repo "$1"
  printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
  printf '{"issues": []}' > "$FAKE_GH_DIR/issues.json"; rm -f "$FAKE_GH_DIR/fail"
}
pull_request() { python3 -c 'import json, sys; print((json.load(open(sys.argv[1])).get("pr") or {}).get(sys.argv[2], ""))' "$FAKE_GH_DIR/issues.json" "$1"; }
set_pull_request() { python3 -c 'import json, sys; github_record = json.load(open(sys.argv[1])); github_record["pr"] = json.loads(sys.argv[2]); json.dump(github_record, open(sys.argv[1], "w"))' "$FAKE_GH_DIR/issues.json" "$1"; }
merge_pull_request() { python3 -c 'import json, sys; github_record = json.load(open(sys.argv[1])); github_record["pr"]["state"] = "MERGED"; json.dump(github_record, open(sys.argv[1], "w"))' "$FAKE_GH_DIR/issues.json"; }
item_status() { "$local_adapter/read.sh" "$1" | json_value status; }
epic_with_work() {
  worked_epic="$("$local_adapter/create.sh" epic "$1" --body x)"
  remote_branch "$(epic_of "$worked_epic")"; remote_commit "$(epic_of "$worked_epic")" "$(slug "$worked_epic").txt"
  printf '%s' "$worked_epic"
}
pass_closeout() {
  "$local_adapter/write-state.sh" "$1" step=closeout profile=epic
  start_step "$1"
  step_result "$1" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
  finish_step "$1"
}

echo "epic closeout: a passed closeout opens the epic's pull request"
github_repository merging
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

echo "epic closeout: an epic the tracker refuses to close is closed by a later sweep"
github_repository retried
sed -i.bak 's/^  default: local$/  default: github/' .flow/config.yaml && rm -f .flow/config.yaml.bak
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/1"}]}\n' > "$FAKE_GH_DIR/issues.json"
export FLOW_GH_RETRY_WAIT="0 0"
tracked="$("$plugin/adapters/github/create.sh" epic "Loans" --body x)"
tracked_field() { "$plugin/adapters/github/read.sh" "$tracked" | json_value "$1"; }
remote_branch "$(epic_of "$tracked")"; remote_commit "$(epic_of "$tracked")" loans.txt
"$plugin/adapters/github/write-state.sh" "$tracked" step=closeout profile=epic
start_step "$tracked"
step_result "$tracked" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
finish_step "$tracked"
merge_pull_request
check "GitHubEpicWithAMergedPullRequest_WaitsAtTheMergeGateBeforeTheSweep: the closeout left it there, or the checks below prove nothing" \
  '[ "$(tracked_field status)" = open ] && [ "$(tracked_field state.gate)" = merge ]'
printf '9\nGitHub refused the close\nissue close\n' > "$FAKE_GH_DIR/fail"
"$plugin/scripts/steward.sh" sweep > "$work/sweep-refused.out" 2>&1
rm -f "$FAKE_GH_DIR/fail"
check "MergedEpicTheTrackerRefusesToClose_KeepsItsMergeGate: the gate record is what the next sweep finds the epic by" \
  '[ "$(tracked_field status)" = open ] && [ "$(tracked_field state.gate)" = merge ]'
check "MergedEpicTheTrackerRefusesToClose_IsNotSaidToBeClosed: the sweep reports what happened" \
  '! grep -qF "$tracked: closed" "$work/sweep-refused.out"'
"$plugin/scripts/steward.sh" sweep >/dev/null 2>&1
check "MergedEpicTheTrackerRefusedToClose_IsClosedByTheNextSweep: a failed close is tried again" \
  '[ "$(tracked_field status)" = closed ] && [ "$(tracked_field state.gate)" = none ]'

echo "epic closeout: a tracker that refuses to close an epic with nothing to merge leaves the closeout to run again"
github_repository unclosed
sed -i.bak 's/^  default: local$/  default: github/' .flow/config.yaml && rm -f .flow/config.yaml.bak
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/1"}]}\n' > "$FAKE_GH_DIR/issues.json"
tracked="$("$plugin/adapters/github/create.sh" epic "Preseason" --body x)"
"$plugin/adapters/github/write-state.sh" "$tracked" step=closeout profile=epic
start_step "$tracked"
step_result "$tracked" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
printf '9\nGitHub refused the close\nissue close\n' > "$FAKE_GH_DIR/fail"
finish_step "$tracked"
rm -f "$FAKE_GH_DIR/fail"
check "EpicWithNothingToMergeTheTrackerRefusesToClose_RaisesAnEscalationGate: an open epic at done with no gate is one nothing ever looks at again" \
  '[ "$(tracked_field status)" = open ] && [ "$(tracked_field state.gate)" = escalation ]'
check "EpicWithNothingToMergeTheTrackerRefusesToClose_StaysAtCloseout: clearing the gate runs the closeout again" \
  '[ "$(tracked_field state.step)" = closeout ]'
"$plugin/scripts/gate.sh" clear "$tracked" >/dev/null 2>&1
start_step "$tracked"
step_result "$tracked" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
finish_step "$tracked"
check "EpicTheTrackerRefusedToClose_IsClosedByTheCloseoutAfterTheGateClears: the retry is what the gate promised" \
  '[ "$(tracked_field status)" = closed ]'

echo "epic closeout: a pull request that was never recorded on the epic is found by its epic branch"
github_repository unrecorded
lost="$(epic_with_work "Derbies")"
pass_closeout "$lost"
"$local_adapter/write-state.sh" "$lost" pr=
merge_pull_request
check "EpicWhosePullRequestWasNeverRecorded_HasNoneInItsState: the record is gone, or the check below proves nothing" \
  '[ -z "$(state "$lost" pr)" ] && [ "$(state "$lost" gate)" = merge ]'
"$plugin/scripts/steward.sh" sweep >/dev/null 2>&1
check "EpicWhosePullRequestWasNeverRecorded_IsClosedByTheSweepOnceItMerges: the epic branch names the PR as a task branch names a claim's" \
  '[ "$(item_status "$lost")" = closed ] && [ "$(state "$lost" gate)" = none ]'

echo "epic closeout: an epic with nothing to merge is closed"
github_repository nothing
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
github_repository taken
owned="$(epic_with_work "Transfers")"
set_pull_request "{\"number\": 77, \"state\": \"OPEN\", \"url\": \"https://gh/pull/77\", \"headRefName\": \"$(epic_of "$owned")\", \"baseRefName\": \"main\"}"
pass_closeout "$owned"
check "EpicCloseoutWithAnOpenPullRequestFromItsBranch_RecordsThatOne: the owner's PR is not doubled" \
  '[ "$(state "$owned" pr)" = https://gh/pull/77 ] && [ "$(pull_request number)" = 77 ]'

echo "epic closeout: an epic under an epic merges into that epic's branch"
github_repository nested
outer="$("$local_adapter/create.sh" epic "Season" --body x)"
remote_branch "$(epic_of "$outer")"
inner="$("$local_adapter/create.sh" epic "Final" --body x --parent "$outer")"
git -C "$root/other" fetch -q origin && git -C "$root/other" push -q origin "origin/$(epic_of "$outer"):refs/heads/$(epic_of "$inner")"
remote_commit "$(epic_of "$inner")" final.txt
pass_closeout "$inner"
check "CloseoutOfAnEpicUnderAnEpicWithABranch_AimsThePullRequestAtThatBranch: the inner epic's work joins the outer epic, not the default branch" \
  '[ "$(pull_request baseRefName)" = "$(epic_of "$outer")" ]'

echo "epic closeout: a pull request gh cannot open is the owner's to open"
github_repository refused
stuck="$(epic_with_work "Awards")"
printf '9\nGitHub is down\n' > "$FAKE_GH_DIR/fail"
pass_closeout "$stuck"
check "EpicCloseoutWhosePullRequestCannotBeOpened_RaisesAnEscalationGate: the owner hears the closeout passed and the PR is missing" \
  '[ "$(state "$stuck" gate)" = escalation ]'
check "EpicCloseoutWhosePullRequestCannotBeOpened_NamesTheCommandInTheGate: the owner can open the PR without working out the branches" \
  'json_value message < ".flow/gates/$(slug "$stuck").json" | grep -qF -- "--head $(epic_of "$stuck")"'
check "EpicCloseoutWhosePullRequestCannotBeOpened_LeavesTheEpicOpenAtCloseout: clearing the gate runs the closeout again, which takes the PR the owner opened" \
  '[ "$(item_status "$stuck")" = open ] && [ "$(state "$stuck" step)" = closeout ]'

echo "epic closeout: a base that is not on the remote is no empty difference"
github_repository baseless
adrift="$(epic_with_work "Friendlies abroad")"
sed -i.bak 's/^base: main$/base: trunk/' .flow/config.yaml && rm -f .flow/config.yaml.bak
pass_closeout "$adrift"
check "EpicCloseoutWhoseBaseIsNotOnTheRemote_LeavesTheEpicOpen: its branch still holds work nothing merged, so it must not be closed" \
  '[ "$(item_status "$adrift")" = open ]'
check "EpicCloseoutWhoseBaseIsNotOnTheRemote_RaisesAnEscalationGate: the owner hears the branch has nowhere to merge" \
  '[ "$(state "$adrift" gate)" = escalation ] && json_value message < ".flow/gates/$(slug "$adrift").json" | grep -qF "trunk is not on the remote"'

echo "epic closeout: a remote that cannot be reached is no missing epic branch"
github_repository unreachable
far="$(epic_with_work "Away games")"
git remote set-url origin "$work/no-such-remote.git"
pass_closeout "$far"
check "EpicCloseoutWithAnUnreachableRemote_LeavesTheEpicOpen: its branch may hold work nobody merged, so not seeing it is no proof" \
  '[ "$(item_status "$far")" = open ]'
check "EpicCloseoutWithAnUnreachableRemote_RaisesAnEscalationGate: the owner hears the remote could not be asked" \
  '[ "$(state "$far" gate)" = escalation ] && json_value message < ".flow/gates/$(slug "$far").json" | grep -qF "could not be asked"'

echo "epic closeout: a fetch the remote refuses is no empty difference"
github_repository stale
moved_on="$("$local_adapter/create.sh" epic "Cup replays" --body x)"
remote_branch "$(epic_of "$moved_on")"; git fetch -q origin "$(epic_of "$moved_on")"
remote_commit "$(epic_of "$moved_on")" replays.txt
"$local_adapter/write-state.sh" "$moved_on" step=closeout profile=epic
start_step "$moved_on"
step_result "$moved_on" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
mkdir -p "$work/git-that-refuses-fetch"
printf '#!/bin/sh\ncase " $* " in *" fetch "*) echo "fatal: the remote refused the fetch" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$work/git-that-refuses-fetch/git"
chmod +x "$work/git-that-refuses-fetch/git"
(PATH="$work/git-that-refuses-fetch:$PATH"; export PATH; finish_step "$moved_on")
check "EpicBranchCachedAtItsBaseWhileTheRemoteMovedOn_HasNothingAheadLocally: the stale copy shows no work, or the checks below prove nothing" \
  '[ "$(git rev-list --count "origin/main..origin/$(epic_of "$moved_on")")" = 0 ] && [ "$(remote_tip "$(epic_of "$moved_on")")" != "$(remote_tip main)" ]'
check "EpicCloseoutWhoseBranchCannotBeFetched_LeavesTheEpicOpen: a stale copy of the branch is no proof that nothing is left to merge" \
  '[ "$(item_status "$moved_on")" = open ]'
check "EpicCloseoutWhoseBranchCannotBeFetched_RaisesAnEscalationGate: the owner hears the branch could not be fetched" \
  '[ "$(state "$moved_on" gate)" = escalation ] && json_value message < ".flow/gates/$(slug "$moved_on").json" | grep -qF "could not be fetched"'

echo "epic closeout: a clone that tracks only the default branch still sees the epic's work"
github_repository narrowed
tracked_apart="$("$local_adapter/create.sh" epic "Cup draws" --body x)"
remote_branch "$(epic_of "$tracked_apart")"; git fetch -q origin "$(epic_of "$tracked_apart"):refs/remotes/origin/$(epic_of "$tracked_apart")"
git config remote.origin.fetch "+refs/heads/main:refs/remotes/origin/main"
remote_commit "$(epic_of "$tracked_apart")" draws.txt
pass_closeout "$tracked_apart"
check "EpicCloseoutInACloneThatTracksOnlyTheDefaultBranch_OpensThePullRequest: the fetch must refresh the very copy the comparison reads, or the remote's newer work looks merged" \
  '[ "$(pull_request headRefName)" = "$(epic_of "$tracked_apart")" ] && [ "$(item_status "$tracked_apart")" = open ]'

echo "epic closeout: the closeout of an epic with a branch runs on that branch"
github_repository checked_out
verified="$(epic_with_work "Cup final")"
"$local_adapter/write-state.sh" "$verified" step=closeout profile=epic
closeout_worktree="$("$plugin/scripts/next.sh" "$verified" --json 2>/dev/null | json_value worktree)"
claimed_worktree="$("$plugin/scripts/steward.sh" find "$verified" 2>/dev/null)"
resolved_folder() { if [ -n "$1" ]; then (cd "$1" && pwd -P); else printf 'no %s folder' "$2"; fi; }
check "EpicCloseoutWithAnEpicBranch_StartsInThePoolWorktreeClaimedForTheEpic: the main checkout stays on main, so the epic's work needs a pool worktree of its own" \
  '[ "$(resolved_folder "$closeout_worktree" closeout)" = "$(resolved_folder "$claimed_worktree" claimed)" ]'
check "EpicCloseoutWithAnEpicBranch_StartsAtTheRemoteTipOfTheEpicBranch: the pull request merges the remote tip, so that commit is the one the verifier must check" \
  '[ "$(git -C "${closeout_worktree:-$work/no-closeout-worktree}" rev-parse HEAD)" = "$(remote_tip "$(epic_of "$verified")")" ]'

if [ "$fails" -eq 0 ]; then echo "epic-closeout: ok"; else echo "epic-closeout: $fails failed"; exit 1; fi
