#!/bin/sh
# state-readers.sh: the flow readers take an item's flow state from its record, never from the
# tracker: board.sh --json, steward.sh pool, filter-ready.sh and gate.sh list, on the local adapter
# in a throwaway repo. Each check makes the record and the tracker disagree, so only a reader of
# the record passes. Each mode is set in the repo's config.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
new_repo readers
state_keys="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _state_schema; print(" ".join(_state_schema.STATE_KEYS))' "$plugin/scripts")"
# board_item <item> <key>: one key of the item as board.sh --json shows it.
board_item() { python3 -c 'import json,sys
board=json.load(open(sys.argv[1])); value=[item for item in board["items"] if item["id"]==sys.argv[2]][0]
for key in sys.argv[3].split("."): value=value[key]
print(value if isinstance(value,str) else json.dumps(value))' "$work/board.json" "$1" "$2"; }
# listed_in <file> <key> <item>: the JSON array in <file>, or the array at <key> of its object,
# holds a row of <item>.
listed_in() { python3 -c 'import json,sys
rows=json.load(open(sys.argv[1])); rows=rows[sys.argv[2]] if sys.argv[2] else rows
sys.exit(0 if sys.argv[3] in [row.get("item", row.get("id")) for row in rows] else 1)' "$1" "$2" "$3"; }
# pool_step <item>: the step column of the item's row in steward.sh pool.
pool_step() { "$plugin/scripts/steward.sh" pool | awk -v item="$1" '$3 == item { print $4 }'; }
# set_claim_step <item> <step>: writes <step> into the item's claim.json, as a stale view would hold it.
set_claim_step() { python3 -c 'import json,sys; path=sys.argv[1]; claim=json.load(open(path)); claim["step"]=sys.argv[2]; json.dump(claim,open(path,"w"))' "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json" "$2"; }

echo "board.sh --json: the items' state is the record's"
recorded="$(new_task "Recorded")"
record set "$recorded" step=implement >/dev/null 2>&1
"$local_adapter/write-state.sh" "$recorded" step=review
unrecorded="$(new_task "Unrecorded")"
"$local_adapter/write-state.sh" "$unrecorded" step=plan
"$plugin/scripts/board.sh" --json > "$work/board.json"
check "BoardJsonOfARecordedItemWhoseTrackerDiffers_ShowsTheRecordsStep: the board reads the record, not the tracker" \
  '[ "$(board_item "$recorded" state.step)" = implement ]'
check "BoardJson_GivesEveryItemTheTwentyOneStateKeys: the console reads state on every item, as before" \
  'python3 -c "import json,sys; items=json.load(open(sys.argv[1]))[\"items\"]; keys=sys.argv[2].split(); sys.exit(0 if items and all(sorted(item[\"state\"])==sorted(keys) for item in items) else 1)" "$work/board.json" "$state_keys"'
check "BoardJson_StampsEveryItemWithWhereItsStateCameFrom: each item says record, tracker or none" \
  'python3 -c "import json,sys; items=json.load(open(sys.argv[1]))[\"items\"]; sys.exit(0 if items and all(item.get(\"state_from\") in (\"record\",\"tracker\",\"none\") for item in items) else 1)" "$work/board.json"'
check "BoardJsonOfAnUnrecordedItemUnderLabels_ShowsTheTrackersStep: an item started before the records keeps its state while the mirror is on" \
  '[ "$(board_item "$unrecorded" state.step)" = plan ]'
tracker_state_is none
"$plugin/scripts/board.sh" --json > "$work/board.json"
check "BoardJsonOfAnUnrecordedItemUnderNone_ShowsNoStep: with the mirror off the board never reads the tracker's state" \
  '[ -z "$(board_item "$unrecorded" state.step)" ]'
tracker_state_is ""

echo "board.sh --json and gate.sh list: runs and gates come from the records"
running="$(new_task "Running")"
record set "$running" "run:=$run_record" >/dev/null 2>&1
gated="$(new_task "Gated")"
record set "$gated" "gate:=$gate_record" >/dev/null 2>&1
"$local_adapter/write-state.sh" "$gated" gate=none
named="$(new_task "Gate named alone")"
record set "$named" gate=plan-approval gate_from=plan >/dev/null 2>&1
"$plugin/scripts/board.sh" --json > "$work/board.json"
check "BoardJsonOfARunInFlight_ListsItInRuns: a run the record holds is a row of the board's runs" \
  'listed_in "$work/board.json" runs "$running"'
check "BoardJsonOfARaisedGateTheTrackerDoesNotShow_ListsItInGates: the gates come from the record" \
  'listed_in "$work/board.json" gates "$gated"'
check "BoardJsonOfAGateNamedAlone_LeavesItOutOfGates: a gate with no notify record has no row" \
  '! listed_in "$work/board.json" gates "$named"'
"$plugin/scripts/gate.sh" list --json > "$work/gates.json"
check "GateListOfARaisedGateTheTrackerDoesNotShow_ListsIt: gate.sh list reads the record" \
  'listed_in "$work/gates.json" "" "$gated"'
record set "$running" "run:=null" >/dev/null 2>&1
record set "$gated" gate=none >/dev/null 2>&1
"$local_adapter/write-state.sh" "$gated" "gate=ambiguity"
"$plugin/scripts/board.sh" --json > "$work/board.json"
check "BoardJsonOfAnEndedRun_LeavesItOutOfRuns: a run ended in the record leaves the board" \
  '! listed_in "$work/board.json" runs "$running"'
check "BoardJsonOfAGateClearedInTheRecord_LeavesItOutOfGates: a gate the tracker still shows is gone once the record clears it" \
  '! listed_in "$work/board.json" gates "$gated"'

echo "filter-ready.sh: readiness is judged on the record"
held_by_record="$(new_task "Gate in the record")"
record set "$held_by_record" gate=plan-approval gate_from=plan >/dev/null 2>&1
"$local_adapter/write-state.sh" "$held_by_record" gate=none
held_by_tracker="$(new_task "Gate on the tracker")"
record set "$held_by_tracker" step=plan >/dev/null 2>&1
"$local_adapter/write-state.sh" "$held_by_tracker" gate=plan-approval
"$local_adapter/list.sh" | "$plugin/scripts/filter-ready.sh" > "$work/ready.json"
check "FilterReadyOfAnItemWhoseRecordWaitsAtAGate_HoldsItBack: a gate the tracker does not show still holds" \
  '! listed_in "$work/ready.json" "" "$held_by_record"'
check "FilterReadyOfAnItemOnlyItsTrackerHoldsAtAGate_KeepsItReady: a stale gate on the tracker holds nothing" \
  'listed_in "$work/ready.json" "" "$held_by_tracker"'

echo "steward.sh pool: the step column is the record's"
claimed="$(new_task "Claimed")"
"$plugin/scripts/steward.sh" claim "$claimed" >/dev/null 2>&1
record set "$claimed" step=review >/dev/null 2>&1
"$local_adapter/write-state.sh" "$claimed" step=plan
set_claim_step "$claimed" plan
check "PoolOfAClaimWhoseTrackerAndClaimDiffer_ShowsTheRecordsStep: the pool reads the record, not a stale view" \
  '[ "$(pool_step "$claimed")" = review ]'
record set "$claimed" 'run:={"step":"verify","profile":"task-M","started":"2026-11-15T11:00:00Z"}' >/dev/null 2>&1
check "PoolOfAClaimWithARunInFlight_ShowsTheRunsStep: the step running is the one the pool shows" \
  '[ "$(pool_step "$claimed")" = verify ]'

[ "$fails" -eq 0 ] && { echo "state-readers: ok"; exit 0; }
echo "state-readers: $fails failed"; exit 1
