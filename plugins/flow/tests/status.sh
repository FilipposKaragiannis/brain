#!/bin/sh
# shellcheck disable=SC2154 # the fixture sourced below sets plugin, work, local_adapter and fails
# shellcheck disable=SC2016,SC2034 # check evaluates each condition, so it stays single-quoted and reads these names
# status.sh: the tracker's status and assignee follow the flow record (lib/push.sh), on the local
# adapter in a throwaway repo. A take that makes the claim assigns the user when nobody holds the
# item and sets it in progress; a take of a claim already held moves nothing; a raised gate sets
# needs-you, the merge gate in-review; a clear in each mode sets in-progress again; the last step
# done sets in-review; a gate dropped and a merge gate cleared at done move nothing. A copy of the
# plugin whose set-status fails shows a push that fails warns, logs a push failed event, keeps
# pushed as it was and leaves the step's exit as it was; one whose set-status keeps what it printed
# shows the same status pushed twice moves the item once.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
unset FLOW_TRACKER_STATE
new_repo status
git_identity_email="$(git config user.email)"
someone_else=bob@status.test
gate_options='[{"label":"Keep the row","text":"Keep the row as it is.","recommended":true}]'
gate_condition=ci:down

stubbed="$work/plugin-stubbed"; cp -R "$plugin" "$stubbed"; rm -rf "$stubbed/evals/results"
mv "$stubbed/adapters/local/set-status.sh" "$stubbed/adapters/local/set-status-tracker.sh"
SET_STATUS_FAILS="$work/set-status-fails"; SET_STATUS_MOVES="$work/set-status-moves"
export SET_STATUS_FAILS SET_STATUS_MOVES
cat > "$stubbed/adapters/local/set-status.sh" <<'STUB'
#!/bin/sh
if [ -f "$SET_STATUS_FAILS" ]; then echo "flow: the tracker refused the status: API rate limit exceeded" >&2; exit 1; fi
"$(dirname "$0")/set-status-tracker.sh" "$@" | tee -a "$SET_STATUS_MOVES"
STUB
chmod +x "$stubbed/adapters/local/set-status.sh"

record() { "$plugin/scripts/state.sh" "$@"; }
take() { sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && take_item "$1"' take "$1"; }
push() { sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && tracker_push "$1"' push "$1"; }
category() { "$local_adapter/read.sh" "$1" | json_value category; }
assignees() { "$local_adapter/read.sh" "$1" | json_value assignees; }
assigned_to() { "$local_adapter/read.sh" "$1" | python3 -c 'import json,sys; sys.exit(sys.argv[1] not in json.load(sys.stdin)["assignees"])' "$2"; }
write_frontmatter() {
  python3 -c 'import sys
path, key, value = sys.argv[1:]
text = open(path).read(); end = text.find("\n---\n", 4)
head = "\n".join(line for line in text[:end].split("\n") if not line.startswith(key + ":"))
open(path, "w").write(head + "\n" + key + ": " + value + text[end:])' ".flow/items/${1#local:}.md" "$2" "$3"
}
raise() { "$plugin/scripts/gate.sh" raise "$1" "$2" "**Which row owns the retune?**" plan --options "$gate_options" --condition "$gate_condition" >/dev/null 2>&1; }
clear_gate() { item_to_clear="$1"; shift; "$plugin/scripts/gate.sh" clear "$item_to_clear" "$@" >/dev/null 2>&1; }
taken_at_implement() { taken_item="$(new_task "$1")"; take "$taken_item"; record set "$taken_item" step=implement >/dev/null; printf '%s' "$taken_item"; }
gated() { gated_item="$(taken_at_implement "$1")"; raise "$gated_item" ambiguity; printf '%s' "$gated_item"; }
events_hold() { grep -F "$(printf '\t%s\t%s\t' "$1" "$2")" .flow/events.log >/dev/null 2>&1; }

echo "status: a take"
unassigned="$(new_task "Nobody holds this")"
take "$unassigned"
check "TakeOfAnUnassignedItem_AssignsMe: the item's assignees hold the git identity, because the flow says on the tracker who works it" \
  'assigned_to "$unassigned" "$git_identity_email"'
check "TakeOfAnUnassignedItem_RecordsAssignedAt: claim.assigned_at is set, because a give back takes off only the assignment the flow made" \
  '[ -n "$(record get "$unassigned" claim.assigned_at)" ]'
check "TakeThatMakesTheClaim_SetsInProgress: the item reads category in-progress, because the flow holds it now" \
  '[ "$(category "$unassigned")" = in-progress ]'
check "TakeThatMakesTheClaim_RecordsPushedStatus: pushed names the in-progress status, because the record keeps what the tracker last took" \
  '[ "$(record get "$unassigned" pushed.status)" = in-progress ]'
check "TakeThatMakesTheClaim_RecordsPushedTime: pushed has the time of the push, because the record says when the tracker took it" \
  '[ -n "$(record get "$unassigned" pushed.at)" ]'

theirs="$(new_task "Bob holds this")"; write_frontmatter "$theirs" assignee "$someone_else"
take "$theirs"
check "TakeOfAnItemSomeoneHolds_KeepsTheirAssignee: the item stays with its assignee alone, because the flow never takes an item off a person" \
  '[ "$(assignees "$theirs")" = "[\"$someone_else\"]" ]'
check "TakeOfAnItemSomeoneHolds_LeavesAssignedAtEmpty: claim.assigned_at stays empty, because the flow made no assignment" \
  '[ -z "$(record get "$theirs" claim.assigned_at)" ]'

held="$(new_task "Held, then moved by hand")"
take "$held"; write_frontmatter "$held" workflow backlog
take "$held"
check "TakeOfAClaimAlreadyHeld_MovesNothing: a hand-moved item stays where it was put, because a step start on a held claim costs no tracker call" \
  '[ "$(category "$held")" = todo ]'

echo "status: a gate"
planned="$(taken_at_implement "Plan waiting")"; raise "$planned" plan-approval
check "RaisedPlanGate_SetsNeedsYou: the item reads category blocked, because the owner holds the next move" \
  '[ "$(category "$planned")" = blocked ]'
merging="$(taken_at_implement "Merge waiting")"; raise "$merging" merge
check "RaisedMergeGate_SetsInReview: the item reads category review, because the PR waits on its review" \
  '[ "$(category "$merging")" = review ]'

answered="$(gated "Cleared with an answer")"; clear_gate "$answered" "Keep the row."
check "GateClearedWithAnAnswer_SetsInProgress: the item reads category in-progress, because the flow works it again" \
  '[ "$(category "$answered")" = in-progress ]'
picked="$(gated "Cleared with an option")"; clear_gate "$picked" --option 1
check "GateClearedWithAnOption_SetsInProgress: the item reads category in-progress, because the flow works it again" \
  '[ "$(category "$picked")" = in-progress ]'
sent_back="$(gated "Sent back")"; clear_gate "$sent_back" --back "Plan the row again."
check "GateSentBack_SetsInProgress: the item reads category in-progress, because the flow works it again" \
  '[ "$(category "$sent_back")" = in-progress ]'
met="$(gated "Cleared by its condition")"; clear_gate "$met" --met "$gate_condition"
check "GateClearedByItsCondition_SetsInProgress: the item reads category in-progress, because the flow works it again" \
  '[ "$(category "$met")" = in-progress ]'
merge_sent_back="$(taken_at_implement "Merge sent back")"
"$plugin/scripts/gate.sh" raise "$merge_sent_back" merge "**Merge the pull request.**" pr -- step="done" >/dev/null 2>&1
clear_gate "$merge_sent_back" --back "Split the PR in two."
check "MergeGateSentBack_SetsInProgress: the item reads category in-progress, because its pr step runs again" \
  '[ "$(category "$merge_sent_back")" = in-progress ]'

dropped="$(gated "Closed under its gate")"; write_frontmatter "$dropped" workflow backlog
"$plugin/scripts/gate.sh" drop "$dropped" "the item closed" >/dev/null 2>&1
check "GateDropped_MovesNothing: the item stays where it was put, because a drop comes on a closed item and close has no status" \
  '[ "$(category "$dropped")" = todo ]'
merged_at_done="$(taken_at_implement "Merge cleared at done")"
"$plugin/scripts/gate.sh" raise "$merged_at_done" merge "**Merge the pull request.**" pr -- step="done" >/dev/null 2>&1
write_frontmatter "$merged_at_done" workflow backlog
clear_gate "$merged_at_done" "Merged."
check "MergeGateClearedAtDone_MovesNothing: the item stays where it was put, because the sweep closed it and its card is in review already" \
  '[ "$(category "$merged_at_done")" = todo ]'

echo "status: the last step"
finished="$(new_task "Every step ran")"; take "$finished"
mkdir -p "$work/reports"
record set "$finished" step=closeout profile=epic >/dev/null
record set "$finished" "run:={\"step\":\"closeout\",\"profile\":\"epic\",\"worktree\":\"$PWD\",\"reports\":\"$work/reports\",\"host\":\"claude\",\"started\":\"2026-11-24T10:00:00Z\",\"touches\":[]}" >/dev/null
"$plugin/scripts/advance.sh" "$finished" --status "done" --summary "Closed out." >/dev/null 2>&1
check "LastStepDone_SetsInReview: the item reads category review, because only its review is left" \
  '[ "$(category "$finished")" = review ]'

echo "status: a push that fails"
failing="$(taken_at_implement "The tracker refuses its status")"
: > "$SET_STATUS_FAILS"
FLOW_PLUGIN="$stubbed" "$stubbed/scripts/gate.sh" raise "$failing" plan-approval "**Approve the plan?**" plan > /dev/null 2> "$work/failing.err"; failing_code=$?
rm -f "$SET_STATUS_FAILS"
check "FailingSetStatus_LeavesTheStepsExit: the gate raise exits 0, because a push never fails the step" \
  '[ "$failing_code" = 0 ]'
check "FailingSetStatus_Warns: stderr names the item whose push failed, because the owner learns its card lags" \
  'grep -qF "$failing" "$work/failing.err"'
check "FailingSetStatus_KeepsThePushedStatus: pushed still names the in-progress of the take, because pushed holds only what the tracker took" \
  '[ "$(record get "$failing" pushed.status)" = in-progress ]'
check "FailingSetStatus_LogsAPushFailedEvent: events.log holds a push failed line for the item, because the console lists what the tracker missed" \
  'events_hold "$failing" "push failed"'

echo "status: a push repeated"
repeated="$(new_task "Pushed twice")"
: > "$SET_STATUS_MOVES"
FLOW_PLUGIN="$stubbed" sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && take_item "$1" && tracker_push "$1"' push "$repeated"
moves_once=1
check "SameStatusPushedTwice_MovesTheItemOnce: set-status moved the item once, because the adapter leaves an item already at its status" \
  '[ "$(grep -c "^$repeated " "$SET_STATUS_MOVES")" = "$moves_once" ]'

[ "$fails" -eq 0 ]
