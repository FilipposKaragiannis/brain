#!/bin/sh
# state-join.sh: the flow record joined onto the adapter's item (item_read, items_join,
# items_listed; scripts/state.sh read and join) and the run and gate rows listed from the records
# (record_list, run_record, gate_record; scripts/state.sh list), on the local adapter in a
# throwaway repo. Each mode is set in the repo's config, but for the checks of FLOW_TRACKER_STATE.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
new_repo records
flow() { sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && "$@"' flow "$@"; }
joined() { record read "$1" | json_value "$2"; }
state_keys="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _state_schema; print(" ".join(_state_schema.STATE_KEYS))' "$plugin/scripts")"

echo "item_read: a record wins, else the tracker under labels, else the empty state"
recorded="$(new_task "Recorded")"
record set "$recorded" step=implement attempts=2 touches=src/a/**,docs/b.md >/dev/null 2>&1
"$local_adapter/write-state.sh" "$recorded" step=review
check "RecordedItemWhoseTrackerDiffers_ReadsTheRecordsStep: once a record exists it is the item's state" \
  '[ "$(joined "$recorded" state.step)" = implement ]'
check "RecordedItem_IsStampedFromTheRecord: a reader can tell the state came from the record" \
  '[ "$(joined "$recorded" state_from)" = record ]'
check "RecordedItem_CarriesEveryStateKey: the joined state holds all twenty keys, set or not" \
  '[ "$(record read "$recorded" | python3 -c "import json,sys; print(\" \".join(json.load(sys.stdin)[\"state\"]))")" = "$state_keys" ]'
check "RecordedItem_KeepsTheAdaptersTypes: attempts reads a number and touches and changes lists, as the adapters emit them" \
  'record read "$recorded" | python3 -c "import json,sys; joined=json.load(sys.stdin)[\"state\"]; tracker=json.loads(sys.argv[1]); sys.exit(0 if tracker and all(type(joined[key]) is type(value) for key, value in tracker.items()) else 1)" "$(tracker "$recorded")"'
check "RecordedItemWithNoGate_ReadsGateNone: a clear gate reads none, as the adapters show it" \
  '[ "$(joined "$recorded" state.gate)" = none ]'
unrecorded="$(new_task "Unrecorded")"
"$local_adapter/write-state.sh" "$unrecorded" step=plan
check "UnrecordedItemUnderLabels_ReadsTheTrackersStep: an item started before the records keeps its state while the mirror is on" \
  '[ "$(joined "$unrecorded" state.step)" = plan ]'
check "UnrecordedItemUnderLabels_IsStampedFromTheTracker: a reader can tell the state is the tracker's" \
  '[ "$(joined "$unrecorded" state_from)" = tracker ]'
check "UnrecordedItem_ReadSeedsNoRecord: a read never starts a record" '[ ! -f "$(record path "$unrecorded")" ]'
tracker_state_is none
check "UnrecordedItemUnderNone_ReadsAnEmptyStep: with the mirror off the tracker's state is never read" \
  '[ -z "$(joined "$unrecorded" state.step)" ]'
check "UnrecordedItemUnderNone_IsStampedNone: a reader can tell the item has no state" \
  '[ "$(joined "$unrecorded" state_from)" = none ]'
check "UnrecordedItemUnderNone_CarriesEveryStateKey: the empty state holds all twenty keys" \
  '[ "$(record read "$unrecorded" | python3 -c "import json,sys; print(\" \".join(json.load(sys.stdin)[\"state\"]))")" = "$state_keys" ]'
check "RecordedItemUnderNone_ReadsTheRecordsStep: the record is read the same in both modes" \
  '[ "$(joined "$recorded" state.step)" = implement ]'
tracker_state_is ""
archived="$(new_task "Archived")"
record set "$archived" step=implement >/dev/null 2>&1; record archive "$archived" >/dev/null 2>&1
"$local_adapter/write-state.sh" "$archived" step=review
check "ArchivedRecord_ReadsAsNoRecord: the join never opens closed/, so a closed item reads the tracker" \
  '[ "$(joined "$archived" state_from)" = tracker ]'

echo "item_read: a failed read"
"$local_adapter/read.sh" local:task/999 >/dev/null 2>&1; missing_code=$?
record read local:task/999 >/dev/null 2>&1; code=$?
check "ItemTheAdapterCannotRead_ExitsWithTheAdaptersCode: a failed read is the adapter's failure, not an empty state" \
  '[ "$missing_code" -ne 0 ] && [ "$code" -eq "$missing_code" ]'
record read adhoc:anything >/dev/null 2>&1; code=$?
check "IdNoAdapterOwns_ExitsTwo: item_read refuses it as adapter read does" '[ "$code" -eq 2 ]'
corrupt="$(new_task "Corrupt record")"
record set "$corrupt" step=implement >/dev/null 2>&1
printf '{ not json' > "$(record path "$corrupt")"
record read "$corrupt" >/dev/null 2>"$work/corrupt.err"; code=$?
check "UnreadableRecord_FailsTheReadWithOne: an item whose record does not parse is never read as empty, which would look ready" \
  '[ "$code" -eq 1 ]'
check "UnreadableRecord_NamesItsFile: the owner is told which record to mend" 'grep -qF "$(record path "$corrupt")" "$work/corrupt.err"'

echo "items_join: a list in one call"
"$local_adapter/list.sh" > "$work/list.json"
record join < "$work/list.json" > "$work/joined.json" 2>"$work/joined.err"
check "ListWithAnUnreadableRecord_LeavesThatItemOut: a corrupt record never joins as an empty state" \
  '! python3 -c "import json,sys; sys.exit(0 if sys.argv[1] in [item[\"id\"] for item in json.load(open(sys.argv[2]))] else 1)" "$corrupt" "$work/joined.json"'
check "ListWithAnUnreadableRecord_NamesItsFile: the item left out is named on stderr" 'grep -qF "$(record path "$corrupt")" "$work/joined.err"'
check "ListWithAnUnreadableRecord_JoinsEveryOtherItem: one corrupt record leaves the list" \
  '[ "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))) + 1)" "$work/joined.json")" = "$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" "$work/list.json")" ]'
check "List_StampsEveryItem: every item of a joined list says where its state came from" \
  'python3 -c "import json,sys; items=json.load(open(sys.argv[1])); sys.exit(0 if items and all(\"state_from\" in item for item in items) else 1)" "$work/joined.json"'
check "List_JoinsTheRecordOfARecordedItem: a recorded item in a list reads its record" \
  '[ "$(python3 -c "import json,sys; print([item for item in json.load(open(sys.argv[1])) if item[\"id\"] == sys.argv[2]][0][\"state\"][\"step\"])" "$work/joined.json" "$recorded")" = implement ]'
printf '{"id":"adhoc:anything","state":{"step":"plan"}}' | record join > "$work/foreign.json"
check "HandFedIdNoAdapterOwns_IsUnrecorded: an id with no record shape joins as unrecorded" \
  '[ "$(json_value state_from < "$work/foreign.json")" = tracker ]'
flow items_listed local > "$work/listed.json" 2>/dev/null
check "ItemsListed_JoinsTheAdaptersList: a listed item reads its record" \
  '[ "$(python3 -c "import json,sys; print([item[\"state_from\"] for item in json.load(open(sys.argv[1])) if item[\"id\"] == sys.argv[2]][0])" "$work/listed.json" "$recorded")" = record ]'
rm -f "$(record path "$corrupt")"

echo "FLOW_TRACKER_STATE: the mode when the config names none"
check "TrackerStateNoneFromTheEnvironment_ReadsTheEmptyState: the variable sets the mode of a config that has no line" \
  '[ "$(env FLOW_TRACKER_STATE=none "$plugin/scripts/state.sh" read "$unrecorded" | json_value state_from)" = none ]'
tracker_state_is labels
check "ConfigLabelsAndEnvironmentNone_ReadsTheTracker: the config wins over the variable" \
  '[ "$(env FLOW_TRACKER_STATE=none "$plugin/scripts/state.sh" read "$unrecorded" | json_value state_from)" = tracker ]'
tracker_state_is ""
env FLOW_TRACKER_STATE=sideways "$plugin/scripts/state.sh" read "$unrecorded" >/dev/null 2>&1; code=$?
check "UnknownTrackerStateFromTheEnvironment_ExitsTwo: a bad mode is refused wherever it is set" '[ "$code" -eq 2 ]'

echo "record_list, run_record, gate_record: the rows the records hold"
running="$(new_task "Running")"
record set "$running" "run:=$run_record" >/dev/null 2>&1
check "RunInFlight_IsListed: a run the record holds is a row of the runs list" \
  '[ "$(record list runs | grep -F "\"item\":\"$running\"" | canonical)" = "$(printf "%s" "$run_record" | with_item "$running")" ]'
check "RunRecordOfARunningItem_IsItsRow: run_record prints the run with the item's id" \
  '[ "$(flow run_record "$running" | canonical)" = "$(printf "%s" "$run_record" | with_item "$running")" ]'
check "ListOfOneItem_ListsOnlyItsRow: list runs <item> holds that item's run alone" \
  '[ "$(record list runs "$running" | wc -l | tr -d " ")" = 1 ]'
record set "$running" "run:=null" >/dev/null 2>&1
check "EndedRun_IsNotListed: a run ended in the record leaves the list" '! record list runs | grep -qF "\"item\":\"$running\""'
check "RunRecordOfAnEndedRun_PrintsNothing: no run, no row" '[ -z "$(flow run_record "$running")" ]'
raised="$(new_task "Raised gate")"
record set "$raised" "gate:=$gate_record" >/dev/null 2>&1
check "RaisedGate_IsListedWithItsRecord: the gates list carries notify.sh's record of the gate" \
  '[ "$(record list gates | grep -F "\"item\":\"$raised\"" | canonical)" = "$(printf "%s" "$gate_record" | with_item "$raised")" ]'
check "GateRecordOfARaisedGate_IsItsRow: gate_record prints the gate with the item's id" \
  '[ "$(flow gate_record "$raised" | canonical)" = "$(printf "%s" "$gate_record" | with_item "$raised")" ]'
named="$(new_task "Gate named alone")"
record set "$named" gate=plan-approval gate_from=plan >/dev/null 2>&1
check "GateNamedAlone_IsNotListed: a gate with no notify record has no row, as it had no gate file" \
  '! record list gates | grep -qF "\"item\":\"$named\""'
check "GateRecordOfAGateNamedAlone_PrintsNothing: no notify record, no row" '[ -z "$(flow gate_record "$named")" ]'
record set "$raised" gate=none >/dev/null 2>&1
check "ClearedGate_IsNotListed: a cleared gate leaves the list" '! record list gates | grep -qF "\"item\":\"$raised\""'
broken="$(new_task "Broken record")"
record set "$broken" "run:=$run_record" >/dev/null 2>&1
printf '{ not json' > "$(record path "$broken")"
record set "$running" "run:=$run_record" >/dev/null 2>&1
record list runs > "$work/runs.out" 2>"$work/runs.err"; code=$?
check "ListWithAnUnreadableRecord_ExitsZero: one corrupt record does not fail the list" '[ "$code" -eq 0 ]'
check "ListWithAnUnreadableRecord_ListsTheOtherRuns: the runs of readable records stay listed" 'grep -qF "\"item\":\"$running\"" "$work/runs.out"'
check "ListWithAnUnreadableRecord_NamesItsFileOnStderr: the record left out is named" 'grep -qF "$(record path "$broken")" "$work/runs.err"'
flow run_record "$broken" >/dev/null 2>&1; code=$?
check "RunRecordOfAnUnreadableRecord_ExitsOne: one item's row is never read as none from a corrupt record" '[ "$code" -eq 1 ]'
rm -f "$(record path "$broken")"

echo "record_linked_pr: the PR link-pr left on the tracker"
linked="$(new_task "Linked")"
"$local_adapter/link-pr.sh" "$linked" https://example.invalid/pull/31 >/dev/null
printed="$(flow record_linked_pr "$linked")"
check "LinkedPr_IsCopiedIntoTheRecord: the record takes the PR the worker linked on the tracker" \
  '[ "$(record get "$linked" pr)" = https://example.invalid/pull/31 ]'
check "LinkedPr_IsPrinted: the caller learns the PR it copied" '[ "$printed" = https://example.invalid/pull/31 ]'
unlinked="$(new_task "Unlinked")"
check "NoLinkedPr_PrintsNothing: an item with no PR on the tracker has none to copy" '[ -z "$(flow record_linked_pr "$unlinked")" ]'

[ "$fails" -eq 0 ] && { echo "state-join: ok"; exit 0; }
echo "state-join: $fails failed"; exit 1
