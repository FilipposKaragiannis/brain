#!/bin/sh
# readiness.sh: the ready: policy on the local adapter in a throwaway repo with a shared state.dir.
# ready.assignee and ready.categories read with their defaults, as one value or a list, and a bad
# value exits 2 naming its key; an item a person holds (assigned to someone else, or in progress
# on its tracker) is not ready and is noted why; an item the flow holds (a record claim, or a
# tracker step with no record under tracker_state labels) is judged by its record; a record another
# machine claimed is never ready, noted elsewhere; a failing me stands for no one, said once; and
# next.sh checks the policy again on a named item and on a pick from an older ready list.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$(dirname "$0")/_stale_pick_fixture.sh"
unset FLOW_TRACKER_STATE
this_machine=this-machine; other_machine=other-machine
export FLOW_MACHINE="$this_machine"
exit_usage=2; exit_waiting=4; exit_step_ready=0
new_repo readiness
git_identity_email="$(git config user.email)"
printf 'state:\n  dir: %s\n' "$work/shared-state" >> .flow/config.yaml
cp .flow/config.yaml "$work/base-config.yaml"

config_with_lines() { cp "$work/base-config.yaml" .flow/config.yaml && printf '%s\n' "$1" >> .flow/config.yaml; }
write_frontmatter() {
  python3 -c 'import sys
path, key, value = sys.argv[1:]
text = open(path).read(); end = text.find("\n---\n", 4)
head = "\n".join(line for line in text[:end].split("\n") if not line.startswith(key + ":"))
open(path, "w").write(head + "\n" + key + ": " + value + text[end:])' ".flow/items/${1#local:}.md" "$2" "$3"
}
is_ready() { ready_ids | grep -qxF "$1"; }
held_back_why() {
  held_back_notes="$(mktemp "$work/notes.XXXXXX")"
  FLOW_READY_NOTES="$held_back_notes" "$local_adapter/list-ready.sh" >/dev/null 2>&1
  python3 -c 'import json,sys
for line in open(sys.argv[1]):
    note = json.loads(line)
    if note["id"] == sys.argv[2]: print(note["why"])' "$held_back_notes" "$1"
}
take_on_machine() { env FLOW_MACHINE="$1" sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && take_item "$1"' take "$2"; }
list_code() { "$local_adapter/list.sh" >/dev/null 2>&1; echo $?; }
filter_code_with_exported_policy() { printf '[]' | env READY_ASSIGNEE=none,me READY_CATEGORIES=todo,unknown "$plugin/scripts/filter-ready.sh" >/dev/null 2>&1; echo $?; }
end_runs_and_close_every_open_item() {
  for open_item in $("$local_adapter/list.sh" | python3 -c 'import json,sys; print("\n".join(item["id"] for item in json.load(sys.stdin)))'); do
    "$plugin/scripts/state.sh" set "$open_item" run:=null >/dev/null 2>&1
    "$local_adapter/close.sh" "$open_item" >/dev/null 2>&1
  done
}
next_code() { "$plugin/scripts/next.sh" "$1" >/dev/null 2>&1; echo $?; }

unassigned="$(new_task "Nobody holds this")"
theirs="$(new_task "Bob took this")"; write_frontmatter "$theirs" assignee bob
mine="$(new_task "The owner took this")"; write_frontmatter "$mine" assignee "$git_identity_email"
started="$(new_task "Moved to in progress")"; write_frontmatter "$started" workflow in-progress
queued="$(new_task "In the backlog column")"; write_frontmatter "$queued" workflow backlog

echo "readiness: the policy keys"
check "NoReadyKeys_UnassignedItemWithNoWorkflowIsReady: an item nobody holds and no board places stays ready, because the defaults take none and unknown" 'is_ready "$unassigned"'
check "NoReadyKeys_ItemAssignedToSomeoneElseIsNotReady: the default leaves out a person's item, because ready.assignee defaults to none and me" '! is_ready "$theirs"'
check "NoReadyKeys_ItemAssignedToTheGitIdentityIsReady: the default takes the owner's own item, because me stands for the git identity" 'is_ready "$mine"'
check "NoReadyKeys_InProgressItemIsNotReady: the default leaves out an item in progress on its tracker, because ready.categories defaults to todo and unknown" '! is_ready "$started"'
check "NoReadyKeys_TodoItemIsReady: the default takes an item in the backlog column, because todo is a default category" 'is_ready "$queued"'
config_with_lines 'ready:
  categories: [todo]'
check "CategoriesTodoOnly_UnknownItemIsNotReady: a list without unknown leaves out an item no board places, because only the listed categories are ready" '! is_ready "$unassigned"'
check "CategoriesTodoOnly_TodoItemIsReady: a list of todo still takes a backlog item, because the list names it" 'is_ready "$queued"'
config_with_lines 'ready:
  assignee: any'
check "AssigneeAny_ItemAssignedToSomeoneElseIsReady: any takes a person's item, because any matches every item" 'is_ready "$theirs"'
config_with_lines 'ready:
  assignee: bob'
check "AssigneeSingleLogin_ThatPersonsItemIsReady: one login as a value takes that person's item, because a single value still reads" 'is_ready "$theirs"'
check "AssigneeSingleLogin_UnassignedItemIsNotReady: one login without none leaves out an item nobody holds, because the value replaces the default" '! is_ready "$unassigned"'
config_with_lines 'ready:
  assignee: [none, bob]'
check "AssigneeListWithNone_UnassignedItemIsReady: a list holding none takes an item nobody holds, because an item matches any entry" 'is_ready "$unassigned"'
check "AssigneeListWithALogin_ThatPersonsItemIsReady: a list holding a login takes that person's item, because an item matches any entry" 'is_ready "$theirs"'
config_with_lines 'ready:
  categories: [todo, in-progress]'
check "UnknownCategory_ListExitsTwo: a category outside todo and unknown stops the list, because a bad policy is refused at the boundary" '[ "$(list_code)" = "$exit_usage" ]'
check "UnknownCategory_NamesTheKey: the refusal names ready.categories, because that is the key to change" '"$local_adapter/list.sh" 2>&1 >/dev/null | grep -qF ready.categories'
check "BadCategoryWithThePolicyExported_FilterExitsTwo: filter-ready refuses a bad ready.categories though its caller exported a good policy, because the config is checked on every read" '[ "$(filter_code_with_exported_policy)" = "$exit_usage" ]'
config_with_lines 'ready:
  assignee: [bob smith]'
check "AssigneeWithASpace_ListExitsTwo: an assignee with a space stops the list, because no login holds one" '[ "$(list_code)" = "$exit_usage" ]'
check "AssigneeWithASpace_NamesTheKey: the refusal names ready.assignee, because that is the key to change" '"$local_adapter/list.sh" 2>&1 >/dev/null | grep -qF ready.assignee'
config_with_lines 'ready:
  assignee: []'
check "EmptyAssigneeList_ListExitsTwo: an empty list stops the list, because leaving the key out is how to take the default" '[ "$(list_code)" = "$exit_usage" ]'
config_with_lines 'ready:
  categories: []'
check "EmptyCategoryList_ListExitsTwo: an empty category list stops the list, because it would make nothing ready" '[ "$(list_code)" = "$exit_usage" ]'
config_with_lines ''

echo "readiness: why an item is held back"
check "ItemAssignedToSomeoneElse_IsNotedAssigned: the note says assigned, because next.sh tells the owner why nothing was picked" '[ "$(held_back_why "$theirs")" = assigned ]'
check "InProgressItem_IsNotedStatus: the note says status, because the tracker's category held it back" '[ "$(held_back_why "$started")" = status ]'

echo "readiness: an item the flow holds is judged by its record"
held="$(new_task "Held at design")"
"$plugin/scripts/state.sh" set "$held" step=design >/dev/null 2>&1
take_on_machine "$this_machine" "$held" >/dev/null 2>&1
write_frontmatter "$held" assignee bob; write_frontmatter "$held" workflow in-progress
check "HeldItemAtDesignStep_StaysReadyThoughAssignedAndInProgress: a record claim with no worktree keeps the item the flow's, because the flow set its card and assignees" 'is_ready "$held"'
seeded="$(new_task "Step on the tracker, no record")"
"$local_adapter/write-state.sh" "$seeded" step=design >/dev/null 2>&1
write_frontmatter "$seeded" assignee bob
check "TrackerStepWithNoRecordUnderLabels_CountsAsHeld: a tracker step with no record is the flow's item, because under labels the tracker's state seeds the record" 'is_ready "$seeded"'
config_with_lines 'tracker_state: none'
check "TrackerStepWithNoRecordUnderNone_IsJudgedAsUnheld: a tracker step is no hold under none, because the tracker's state is not the flow's there" '! is_ready "$seeded"'
config_with_lines ''

echo "readiness: a record another machine holds"
elsewhere="$(new_task "Taken on another machine")"
env FLOW_MACHINE="$other_machine" "$plugin/scripts/state.sh" set "$elsewhere" step=design >/dev/null 2>&1
take_on_machine "$other_machine" "$elsewhere" >/dev/null 2>&1
check "RecordClaimedOnAnotherMachine_IsNotReady: an item another machine claimed in the shared state.dir is never ready, because two machines must not run one item" '! is_ready "$elsewhere"'
check "RecordClaimedOnAnotherMachine_IsNotedElsewhere: the note says elsewhere, because the owner must know which machine holds it" '[ "$(held_back_why "$elsewhere")" = elsewhere ]'
check "NamedItemClaimedOnAnotherMachine_NextExitsFour: next.sh will not run an item another machine holds, because the fresh read keeps it back" '[ "$(next_code "$elsewhere")" = "$exit_waiting" ]'

echo "readiness: a me that fails"
printf '[%s,%s,%s]' \
  '{"id":"gh#701","kind":"task","status":"open","state":{"gate":"none"},"blocked_by":[],"open_children":0,"category":"unknown","assignees":[]}' \
  '{"id":"gh#702","kind":"task","status":"open","state":{"gate":"none"},"blocked_by":[],"open_children":0,"category":"unknown","assignees":["owner"]}' \
  '{"id":"gh#703","kind":"task","status":"open","state":{"gate":"none"},"blocked_by":[],"open_children":0,"category":"unknown","assignees":["owner"]}' \
  > "$work/offline-items.json"
"$plugin/scripts/filter-ready.sh" < "$work/offline-items.json" > "$work/offline-ready.json" 2> "$work/offline-ready.err"
check "MeFails_UnassignedItemStaysReady: an item nobody holds is ready while me cannot be read, because none needs no identity" 'grep -qF "\"gh#701\"" "$work/offline-ready.json"'
check "MeFails_AssignedItemIsNotReady: an assigned item is held back while me cannot be read, because a failed me stands for no one" '! grep -qF "\"gh#702\"" "$work/offline-ready.json"'
check "MeFailsForTwoAssignedItems_IsOneStderrLine: the failure is said on one line for two assigned items, because me is read once per adapter" '[ "$(grep -c . "$work/offline-ready.err")" = 1 ]'
check "MeFails_TheWarningNamesTheAdapter: the failure names the github adapter, because the owner must know which tracker's me to fix" 'grep -qw github "$work/offline-ready.err"'

echo "readiness: next.sh checks the fresh read"
check "NamedItemAssignedToSomeoneElse_NextExitsFour: next.sh passes over a named item a person holds, because the policy applies to a named item too" '[ "$(next_code "$theirs")" = "$exit_waiting" ]'
check "NamedHeldItemAtALaterStep_NextRunsIt: next.sh runs the flow's own item though it is assigned and in progress, because a held item is judged by its record" '[ "$(next_code "$held")" = "$exit_step_ready" ]'
end_runs_and_close_every_open_item
taken_since="$(new_task "First in the list")"
still_free="$(new_task "Second in the list")"
stale="$("$local_adapter/list-ready.sh")"
write_frontmatter "$taken_since" assignee bob
picked="$(stale_pick "$stale" 2>/dev/null | json_value item)"
check "StaleListItemAPersonTookSince_PickTakesTheNextOne: a pick from an older ready list passes over the item a person took and takes the next, because the fresh read wins" '[ "$picked" = "$still_free" ]'

[ "$fails" -eq 0 ] && { echo "readiness: ok"; exit 0; }
echo "readiness: $fails failed"; exit 1
