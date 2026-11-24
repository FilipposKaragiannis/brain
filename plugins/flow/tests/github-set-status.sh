#!/bin/sh
# shellcheck disable=SC2154 # the fixture sourced below sets plugin, here, work and fails
# github-set-status.sh: the GitHub adapter's set-status through a fake gh: the card on
# github.project under renamed Statuses, a card added or left where it is, a Status the project
# lacks, nothing called with neither a project nor github.claim_label, and that label put on and
# taken off without a project.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
github_adapter="$plugin/adapters/github"
export FLOW_HOME="$work/flow" FAKE_GH_DIR="$work/gh" FLOW_GH_RETRY_WAIT="0 0"
mkdir -p "$FLOW_HOME" "$FAKE_GH_DIR" "$work/bin" && cp "$here/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$here/fake-gh.sh" "$work/bin/gh"
PATH="$work/bin:$PATH"; export PATH
cd "$work" || exit 1
cat > "$FAKE_GH_DIR/issues.json" <<'JSON'
{"statuses": ["Icebox", "Next up", "Doing", "Waiting on you", "Reviewing"],
 "issues": [
  {"number": 1, "title": "Walks every status", "state": "OPEN", "labels": [], "url": "https://gh/1"},
  {"number": 2, "title": "Doing already", "state": "OPEN", "labels": [], "url": "https://gh/2", "project_item": "PI_2", "project_status": "Doing"},
  {"number": 3, "title": "Not on the board", "state": "OPEN", "labels": [], "url": "https://gh/3"},
  {"number": 4, "title": "Claimed by label", "state": "OPEN", "labels": [], "url": "https://gh/4"}
]}
JSON
# github_config <lines that end the github section>: the project's config on the GitHub adapter.
github_config() {
  printf 'adapters:\n  default: github\nbase: main\nnotify:\n  desktop: false\ngithub:\n  repo: acme/widgets\n%s\n' "$1" > "$FLOW_HOME/config.yaml"
}
renamed_statuses='  status:
    backlog: Icebox
    ready: Next up
    running: Doing
    gate: Waiting on you
    review: Reviewing'
claim_label=flow-claimed
# github_field <id> <path>: a field of the adapter item the GitHub adapter reads.
github_field() { "$github_adapter/read.sh" "$1" 2>/dev/null | json_value "$2"; }
labels_hold() { github_field "$1" labels | python3 -c 'import json,sys; sys.exit(sys.argv[1] not in json.load(sys.stdin))' "$2"; }
card_writes() { grep -c updateProjectV2ItemFieldValue "$FAKE_GH_DIR/calls.log"; }
code_of() { "$@" >/dev/null 2>&1; echo $?; }

echo "github set-status on a project"
github_config "  project: 1
$renamed_statuses"
status_rows='backlog=Icebox
ready=Next up
in-progress=Doing
needs-you=Waiting on you
in-review=Reviewing'
while IFS= read -r status_row; do
  flow_status="${status_row%%=*}"; board_status="${status_row#*=}"
  "$github_adapter/set-status.sh" 'gh#1' "$flow_status" >/dev/null 2>&1
  check "SetStatus_LandsOnItsRenamedStatus ($flow_status is $board_status): the card moves to the Status github.status names for it, because a board may call its columns anything" '[ "$(github_field "gh#1" project.status)" = "$board_status" ]'
done <<ROWS
$status_rows
ROWS
"$github_adapter/set-status.sh" 'gh#3' ready >/dev/null 2>&1
check "SetStatusWithoutCard_AddsTheCard: set-status of an issue with no card on the project puts one there, because the card is where the status lives" '[ -n "$(github_field "gh#3" project.item)" ]'
check "SetStatusWithoutCard_SetsItsStatus: the added card has the Status asked for, because adding it is only the first half of the move" '[ "$(github_field "gh#3" project.status)" = "Next up" ]'
: > "$FAKE_GH_DIR/calls.log"
"$github_adapter/set-status.sh" 'gh#2' in-progress >/dev/null 2>&1
check "SetStatusAlreadyThere_WritesNoCard: set-status of a card at the Status asked for writes nothing to the project, because a push repeats on every step and must not cost a write each time" '[ "$(card_writes)" = 0 ]'
github_config "  project: 1
  status:
    review: Nowhere"
check "SetStatusMissingFromProject_ExitsOne: set-status to a Status the project has no option for exits 1, because the tracker could not take the move" '[ "$(code_of "$github_adapter/set-status.sh" "gh#2" in-review)" = 1 ]'
check "SetStatusMissingFromProject_LeavesTheCard: the card stays at its Status when the project has no option for the one asked for, because no other column stands in for it" '[ "$(github_field "gh#2" project.status)" = Doing ]'

echo "github set-status without a project"
github_config ""
: > "$FAKE_GH_DIR/calls.log"
check "SetStatusWithNoBoard_ExitsZero: set-status with neither github.project nor github.claim_label exits 0, because a tracker with no place for a status is no failure" '[ "$(code_of "$github_adapter/set-status.sh" "gh#4" in-progress)" = 0 ]'
check "SetStatusWithNoBoard_CallsNothing: set-status with neither github.project nor github.claim_label makes no gh call, because there is nothing on GitHub to move" '[ ! -s "$FAKE_GH_DIR/calls.log" ]'
github_config "  claim_label: $claim_label"
"$github_adapter/set-status.sh" 'gh#4' in-progress > "$work/claimed.out" 2>/dev/null
check "ClaimLabelInProgress_PutsTheLabelOn: set-status in-progress puts github.claim_label on the issue, because the label is the status without a project" 'labels_hold "gh#4" "$claim_label"'
check "ClaimLabelInProgress_PrintsIdAndLabel: set-status in-progress that puts the label on prints the id and the label, because the label is the tracker's name for the status" '[ "$(cat "$work/claimed.out")" = "gh#4 $claim_label" ]'
check "ClaimLabelInProgress_ReadsCategoryInProgress: an issue with github.claim_label and no project reads category in-progress, because readiness reads back what the flow set" '[ "$(github_field "gh#4" category)" = in-progress ]'
check "ClaimLabelInProgressRepeated_PrintsNothing: a second set-status in-progress prints nothing, because the label is on already" '[ -z "$("$github_adapter/set-status.sh" "gh#4" in-progress 2>/dev/null)" ]'
"$github_adapter/set-status.sh" 'gh#4' needs-you >/dev/null 2>&1
check "ClaimLabelOtherStatus_TakesTheLabelOff: set-status to any other status takes github.claim_label off, because the item is no longer in progress" '! labels_hold "gh#4" "$claim_label"'
check "ClaimLabelOtherStatus_ReadsCategoryUnknown: an issue without the label and no project reads category unknown, because nothing else on GitHub holds its status" '[ "$(github_field "gh#4" category)" = unknown ]'

[ "$fails" -eq 0 ] && { echo "github-set-status: ok"; exit 0; }
echo "github-set-status: $fails failed"; exit 1
