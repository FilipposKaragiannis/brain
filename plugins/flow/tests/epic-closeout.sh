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
MAX_ATTEMPTS="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["max_attempts"])' "$plugin/profiles.json")"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
CLAIM_REFUSED="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && printf %s "$claim_refused"')"
github_repository() {
  new_repo "$1"
  printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
  printf '{"issues": []}' > "$FAKE_GH_DIR/issues.json"; rm -f "$FAKE_GH_DIR/fail"
}
pull_request() { python3 -c 'import json, sys; print((json.load(open(sys.argv[1])).get("pr") or {}).get(sys.argv[2], ""))' "$FAKE_GH_DIR/issues.json" "$1"; }
set_pull_request() { python3 -c 'import json, sys; github_record = json.load(open(sys.argv[1])); github_record["pr"] = json.loads(sys.argv[2]); json.dump(github_record, open(sys.argv[1], "w"))' "$FAKE_GH_DIR/issues.json" "$1"; }
merge_pull_request() { python3 -c 'import json, sys; github_record = json.load(open(sys.argv[1])); github_record["pr"]["state"] = "MERGED"; json.dump(github_record, open(sys.argv[1], "w"))' "$FAKE_GH_DIR/issues.json"; }
item_status() { "$local_adapter/read.sh" "$1" | json_value status; }
claimed_worktree_of() { "$plugin/scripts/steward.sh" find "$1" 2>/dev/null; }
pool_claim_state_of() {
  pool_claim_state_of_table="$("$plugin/scripts/steward.sh" pool)" || { printf 'no pool table'; return; }
  if printf '%s\n' "$pool_claim_state_of_table" | grep -qF " $1 "; then printf claimed; else printf unclaimed; fi
}
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
"$local_adapter/write-state.sh" "$far" step=closeout profile=epic
start_step "$far"
git remote set-url origin "$work/no-such-remote.git"
step_result "$far" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
finish_step "$far"
check "EpicCloseoutWithAnUnreachableRemote_LeavesTheEpicOpen: its branch may hold work nobody merged, so not seeing it is no proof" \
  '[ "$(item_status "$far")" = open ]'
check "EpicCloseoutWithAnUnreachableRemote_RaisesAnEscalationGate: the owner hears the remote could not be asked" \
  '[ "$(state "$far" gate)" = escalation ] && json_value message < ".flow/gates/$(slug "$far").json" | grep -qF "could not be asked"'

echo "epic closeout: a fetch the remote refuses is no empty difference"
github_repository stale
moved_on="$("$local_adapter/create.sh" epic "Cup replays" --body x)"
remote_branch "$(epic_of "$moved_on")"; git fetch -q origin "$(epic_of "$moved_on")"
"$local_adapter/write-state.sh" "$moved_on" step=closeout profile=epic
start_step "$moved_on"
remote_commit "$(epic_of "$moved_on")" replays.txt
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
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
closeout_worktree="$("$plugin/scripts/next.sh" "$verified" --json 2>/dev/null | json_value worktree)"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
claimed_worktree="$("$plugin/scripts/steward.sh" find "$verified" 2>/dev/null)"
resolved_folder() { if [ -n "$1" ]; then (cd "$1" && pwd -P); else printf 'no %s folder' "$2"; fi; }
check "EpicCloseoutWithAnEpicBranch_StartsInThePoolWorktreeClaimedForTheEpic: the main checkout stays on main, so the epic's work needs a pool worktree of its own" \
  '[ "$(resolved_folder "$closeout_worktree" closeout)" = "$(resolved_folder "$claimed_worktree" claimed)" ]'
check "EpicCloseoutWithAnEpicBranch_StartsAtTheRemoteTipOfTheEpicBranch: the pull request merges the remote tip, so that commit is the one the verifier must check" \
  '[ "$(git -C "${closeout_worktree:-$work/no-closeout-worktree}" rev-parse HEAD)" = "$(remote_tip "$(epic_of "$verified")")" ]'

# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
closeout_brief="$(json_value reports < "$(run_file "$verified")")/brief-closeout.md"
check "EpicCloseoutWithAnEpicBranch_RunsWithTheEpicBranchCheckedOut: verify.sh refuses a HEAD that is not the item's branch, and a detached tip is none" \
  '[ "$(git -C "${closeout_worktree:-$work/no-closeout-worktree}" symbolic-ref --short -q HEAD)" = "$(epic_of "$verified")" ]'
check "EpicCloseoutWithAnEpicBranch_NamesTheEpicBranchInTheBrief: the verifier works on the branch the brief names" \
  'grep -F -- "- Worktree:" "$closeout_brief" | grep -qF "on branch \`$(epic_of "$verified")\`"'
step_result "$verified" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
finish_step "$verified"
check "EpicCloseoutThatPassedWithWorkToMerge_WaitsAtTheMergeGate: the epic's pull request merges only once the owner says so" \
  '[ "$(state "$verified" gate)" = merge ]'
check "EpicCloseoutThatPassedWithWorkToMerge_ReleasesItsWorktree: the sweep closes an epic at the merge gate only while no claim holds it" \
  '[ "$(pool_claim_state_of "$verified")" = unclaimed ]'

echo "epic closeout: the closeout worktree's base is the branch the epic started from"
github_repository started
season="$("$local_adapter/create.sh" epic "Season" --body x)"
remote_branch "$(epic_of "$season")"
final_round="$("$local_adapter/create.sh" epic "Final round" --body x --parent "$season")"
git -C "$root/other" fetch -q origin && git -C "$root/other" push -q origin "origin/$(epic_of "$season"):refs/heads/$(epic_of "$final_round")"
remote_commit "$(epic_of "$final_round")" final-round.txt
"$local_adapter/write-state.sh" "$final_round" step=closeout profile=epic
start_step "$final_round"
check "EpicCloseoutOfAnEpicUnderAnEpicWithABranch_ClaimsWithThatBranchAsItsBase: the claim's base is the outer epic's branch, the one the epic started from and verify compares its work with" \
  '[ "$(claim_base "$final_round")" = "$(epic_of "$season")" ]'

echo "epic closeout: the closeout worktree is set up for the epic's tip"
github_repository set_up
printf 'worktree_name: ../grown-{n}\nworktree_copy:\n  - local.env\nworktree_setup:\n  - mkdir -p installed && git rev-parse HEAD > installed/from\nworktree_setup_paths:\n  - "**/package-lock.json"\n' >> .flow/config.yaml
printf 'installed/\nlocal.env\n' >> .git/info/exclude
printf 'secret\n' > local.env
for pool_folder in wt-1 wt-2 wt-3; do "$plugin/scripts/steward.sh" reserve "$root/$pool_folder" --name owner >/dev/null 2>&1; done
locked="$("$local_adapter/create.sh" epic "Locked squads" --body x)"
remote_branch "$(epic_of "$locked")"; remote_commit "$(epic_of "$locked")" package-lock.json
"$local_adapter/write-state.sh" "$locked" step=closeout profile=epic
start_step "$locked"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
locked_worktree="$(claimed_worktree_of "$locked")"
check "EpicCloseoutWhoseBranchChangesASetupPath_RunsTheSetupAtTheEpicTip: a check that needs installed files runs against the epic's own lockfile" \
  '[ "$(cat "$locked_worktree/installed/from")" = "$(remote_tip "$(epic_of "$locked")")" ]'
check "EpicCloseoutInAGrownPool_HoldsTheWorktreeCopyFiles: the closeout worktree is a pool worktree set up like any other" \
  '[ -f "$locked_worktree/local.env" ]'

echo "epic closeout: an epic with no epic branch closes out in the main checkout"
github_repository branchless
plain="$("$local_adapter/create.sh" epic "Testimonials" --body x)"
"$local_adapter/write-state.sh" "$plain" step=closeout profile=epic
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
plain_worktree="$("$plugin/scripts/next.sh" "$plain" --json 2>/dev/null | json_value worktree)"
check "EpicCloseoutWithNoEpicBranch_StartsInTheMainCheckout: there is no branch of the epic's own to check out" \
  '[ "$(resolved_folder "$plain_worktree" closeout)" = "$(resolved_folder "$root/app" main)" ]'
check "EpicCloseoutWithNoEpicBranch_ClaimsNoPoolWorktree: a claim would hold a worktree nothing runs in" \
  '[ "$(pool_claim_state_of "$plain")" = unclaimed ]'
step_result "$plain" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
finish_step "$plain"
check "EpicCloseoutWithNoEpicBranch_LeavesTheMainCheckoutOnMain: releasing the run's worktree by path would move the main checkout to an idle branch" \
  '[ "$(git -C "$root/app" symbolic-ref --short -q HEAD)" = main ]'

echo "epic closeout: every outcome of a closeout releases its worktree"
github_repository outcomes
closeout_with() {
  "$local_adapter/write-state.sh" "$1" step=closeout profile=epic "attempts=$3"
  start_step "$1"
  step_result "$1" closeout "$2"
  finish_step "$1"
}
level_epic="$("$local_adapter/create.sh" epic "Level" --body x)"
remote_branch "$(epic_of "$level_epic")"
closeout_with "$level_epic" "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}" 0
check "EpicCloseoutThatPassedWithNothingToMerge_ClosesTheEpic: with nothing on its branch that the base lacks, there is no pull request to wait for" \
  '[ "$(item_status "$level_epic")" = closed ]'
check "EpicCloseoutThatPassedWithNothingToMerge_ReleasesItsWorktree: a closed epic keeps no worktree" \
  '[ "$(pool_claim_state_of "$level_epic")" = unclaimed ]'
asking="$(epic_with_work "Asking")"
closeout_with "$asking" '{"status":"gate","gate":"ambiguity","message":"Which cup counts?"}' 0
check "EpicCloseoutThatStopsAtAGate_WaitsAtThatGate: the question the closeout asked is the owner's to answer" \
  '[ "$(state "$asking" gate)" = ambiguity ]'
check "EpicCloseoutThatStopsAtAGate_ReleasesItsWorktree: the owner may take days to answer, and the closeout after it claims the tip again" \
  '[ "$(pool_claim_state_of "$asking")" = unclaimed ]'
failing="$(epic_with_work "Failing")"
closeout_with "$failing" '{"status":"fail","summary":"A check failed."}' 0
check "EpicCloseoutThatFails_CountsAnAttempt: a failed closeout runs again until its attempts run out" \
  '[ "$(state "$failing" attempts)" = 1 ]'
check "EpicCloseoutThatFails_ReleasesItsWorktree: the health job would merge the base into a claimed branch no run holds" \
  '[ "$(pool_claim_state_of "$failing")" = unclaimed ]'
exhausted="$(epic_with_work "Exhausted")"
closeout_with "$exhausted" '{"status":"fail","summary":"A check failed again."}' "$((MAX_ATTEMPTS - 1))"
check "EpicCloseoutThatFailsItsLastAttempt_RaisesAnEscalationGate: a closeout out of attempts needs the owner" \
  '[ "$(state "$exhausted" gate)" = escalation ]'
check "EpicCloseoutThatFailsItsLastAttempt_ReleasesItsWorktree: the escalation gate waits on the owner, not on a worktree" \
  '[ "$(pool_claim_state_of "$exhausted")" = unclaimed ]'
unopened="$(epic_with_work "Unopened")"
printf '9\nGitHub is down\n' > "$FAKE_GH_DIR/fail"
closeout_with "$unopened" "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}" 0
rm -f "$FAKE_GH_DIR/fail"
check "EpicCloseoutInAPoolWorktreeWhosePullRequestCannotBeOpened_RaisesAnEscalationGate: the owner opens the pull request gh refused, then clears the gate" \
  '[ "$(state "$unopened" gate)" = escalation ]'
check "EpicCloseoutWhosePullRequestCannotBeOpened_ReleasesItsWorktree: the owner opens the PR by hand, and the closeout after the gate claims the tip again" \
  '[ "$(pool_claim_state_of "$unopened")" = unclaimed ]'

echo "epic closeout: a tracker that refuses to close an epic whose branch holds nothing new"
github_repository unclosed_branch
sed -i.bak 's/^  default: local$/  default: github/' .flow/config.yaml && rm -f .flow/config.yaml.bak
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/1"}]}\n' > "$FAKE_GH_DIR/issues.json"
unclosed="$("$plugin/adapters/github/create.sh" epic "Charity shield" --body x)"
remote_branch "$(epic_of "$unclosed")"
"$plugin/adapters/github/write-state.sh" "$unclosed" step=closeout profile=epic
start_step "$unclosed"
step_result "$unclosed" closeout "{\"status\":\"done\",\"summary\":\"$CLOSEOUT_SUMMARY\"}"
printf '9\nGitHub refused the close\nissue close\n' > "$FAKE_GH_DIR/fail"
finish_step "$unclosed"
rm -f "$FAKE_GH_DIR/fail"
check "EpicCloseoutInAPoolWorktreeTheTrackerRefusesToClose_RaisesAnEscalationGate: the owner closes the epic the tracker refused to close, or clears the gate to try again" \
  '[ "$("$plugin/adapters/github/read.sh" "$unclosed" | json_value state.gate)" = escalation ]'
check "EpicCloseoutTheTrackerRefusesToClose_ReleasesItsWorktree: clearing the gate runs the closeout again, which claims the tip again" \
  '[ "$(pool_claim_state_of "$unclosed")" = unclaimed ]'

echo "epic closeout: a local epic branch that differs from the remote"
github_repository local_copies
behind="$("$local_adapter/create.sh" epic "Behind" --body x)"
remote_branch "$(epic_of "$behind")"; git fetch -q origin "$(epic_of "$behind"):$(epic_of "$behind")"
remote_commit "$(epic_of "$behind")" behind.txt
"$local_adapter/write-state.sh" "$behind" step=closeout profile=epic
start_step "$behind"
check "EpicCloseoutWithALocalEpicBranchBehindTheRemote_StartsAtTheRemoteTip: a release keeps the local branch, and the remote moved on since" \
  '[ "$(git -C "$(claimed_worktree_of "$behind")" rev-parse HEAD)" = "$(remote_tip "$(epic_of "$behind")")" ]'
ahead="$(epic_with_work "Ahead")"
git fetch -q origin "$(epic_of "$ahead"):$(epic_of "$ahead")"
git update-ref "refs/heads/$(epic_of "$ahead")" "$(git commit-tree -p "$(epic_of "$ahead")" -m unpushed "$(epic_of "$ahead")^{tree}")"
"$local_adapter/write-state.sh" "$ahead" step=closeout profile=epic
start_step "$ahead"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
ahead_code=$?
check "EpicCloseoutWithALocalEpicBranchAheadOfTheRemote_IsRefused: its unpushed commits are not in the pull request, so the remote tip would not be what passed" \
  '[ "$ahead_code" = "$CLAIM_REFUSED" ]'
check "EpicCloseoutWithALocalEpicBranchAheadOfTheRemote_ClaimsNoWorktree: a refused closeout holds nothing" \
  '[ "$(pool_claim_state_of "$ahead")" = unclaimed ]'
held="$(epic_with_work "Held")"
git fetch -q origin "$(epic_of "$held"):$(epic_of "$held")"
git worktree add -q "$root/elsewhere" "$(epic_of "$held")"
"$local_adapter/write-state.sh" "$held" step=closeout profile=epic
start_step "$held"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
held_code=$?
check "EpicCloseoutWithTheEpicBranchCheckedOutElsewhere_IsRefused: git checks a branch out in one worktree at a time" \
  '[ "$held_code" = "$CLAIM_REFUSED" ]'
check "EpicCloseoutWithTheEpicBranchCheckedOutElsewhere_ClaimsNoWorktree: a refused closeout holds nothing" \
  '[ "$(pool_claim_state_of "$held")" = unclaimed ]'
unasked="$(epic_with_work "Unasked")"
"$local_adapter/write-state.sh" "$unasked" step=closeout profile=epic
git remote set-url origin "$work/no-such-remote.git"
start_step "$unasked"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
unasked_code=$?
check "EpicCloseoutWhoseRemoteCannotBeAsked_IsRefused: not seeing the epic branch is no proof it has none" \
  '[ "$unasked_code" = "$CLAIM_REFUSED" ]'
check "EpicCloseoutWhoseRemoteCannotBeAsked_StartsNoRun: a closeout in the main checkout would grade the base instead of the epic" \
  '[ ! -f "$(run_file "$unasked")" ]'

echo "epic closeout: a closeout claim kept after its run ended without advance.sh"
github_repository kept
kept="$(epic_with_work "Kept")"
"$local_adapter/write-state.sh" "$kept" step=closeout profile=epic
start_step "$kept"
# shellcheck disable=SC2034 # read in a check's condition, which check runs whole
kept_worktree="$(claimed_worktree_of "$kept")"
rm -f "$(run_file "$kept")"
remote_commit main first-fixture.txt; remote_commit main second-fixture.txt
"$plugin/scripts/steward.sh" health >/dev/null 2>&1
check "KeptEpicCloseoutClaimBehindItsBase_GetsNoBaseMergeFromTheHealthJob: a local merge would put the epic branch ahead of its remote tip, which the closeout's retry refuses" \
  '[ "$(git rev-parse "refs/heads/$(epic_of "$kept")")" = "$(remote_tip "$(epic_of "$kept")")" ]'
remote_commit "$(epic_of "$kept")" kept-later.txt
start_step "$kept"
check "EpicCloseoutRetriedWhileItsClaimIsKept_RunsInTheKeptWorktree: the claim the epic holds is the one the retry uses" \
  '[ "$(claimed_worktree_of "$kept")" = "${kept_worktree:-no kept worktree}" ]'
check "EpicCloseoutRetriedWhileItsClaimIsKept_StartsAtTheNewRemoteTip: the retry verifies what the pull request merges now" \
  '[ "$(git -C "${kept_worktree:-$work/no-kept-worktree}" rev-parse HEAD)" = "$(remote_tip "$(epic_of "$kept")")" ]'

if [ "$fails" -eq 0 ]; then echo "epic-closeout: ok"; else echo "epic-closeout: $fails failed"; exit 1; fi
