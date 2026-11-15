#!/bin/sh
# state.sh: the flow record of an item (lib/state.sh, scripts/state.sh), on the local adapter in a
# throwaway repo. Every state key and gate record field reads back; a refused write leaves both
# stores as they were; the tracker gets each state write first unless tracker_state is none; two
# writers at once both land; the first write seeds from the tracker; take, archive, and a caller's
# while-read loop keeps its input.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"

record() { "$plugin/scripts/state.sh" "$@"; }
take() { env FLOW_MACHINE="$1" sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && take_item "$1"' take "$2"; }
closed_record() { open_record="$(record path "$1")"; printf '%s/closed/%s' "$(dirname "$open_record")" "$(basename "$open_record")"; }
tracker_state_is() { grep -v '^tracker_state:' .flow/config.yaml > "$work/config.yaml"; [ -z "$1" ] || echo "tracker_state: $1" >> "$work/config.yaml"; cp "$work/config.yaml" .flow/config.yaml; }
tracker() { "$local_adapter/read.sh" "$1" | json_value state; }
item_file() { printf '.flow/items/task/%s.md' "${1##*/}"; }
canonical() { python3 -c 'import json,sys
text=sys.stdin.read().rstrip("\n")
try: print(json.dumps(json.loads(text), sort_keys=True))
except ValueError: print(text)'; }

new_repo records

echo "state keys: each reads back what was set"
keyed="$(new_task "Key round trip")"
while IFS='|' read -r key value expected; do
  record set "$keyed" "$key=$value" >/dev/null 2>&1
  check "Set_${key}_ReadsBackTheValueSet: the record keeps each of the twenty keys as the tracker does" \
    '[ "$(record get "$keyed" "$key")" = "$expected" ]'
done <<'KEYS'
step|implement|implement
profile|task-L|task-L
attempts|3|3
touches|src/a/**,docs/b.md|["src/a/**","docs/b.md"]
changes|lib/c.sh|["lib/c.sh"]
last_event|plan approved by the owner|plan approved by the owner
base|plan/sandbox|plan/sandbox
size|L|L
worktree|wt-2|wt-2
held_by|local:task/9|local:task/9
held_reason|same retune of the row owner|same retune of the row owner
gate|plan-approval|plan-approval
gate_from|design|design
answered|plan-approval|plan-approval
asked|Approve the plan?|Approve the plan?
answer|Approved with notes|Approved with notes
answered_at|2026-11-14T09:30:00Z|2026-11-14T09:30:00Z
answer_pending|next|next
pr|https://example.invalid/pull/7|https://example.invalid/pull/7
pr_host|codex|codex
KEYS
record set "$keyed" step=review >/dev/null 2>&1; record set "$keyed" step= >/dev/null 2>&1
check "EmptyValue_ClearsTheKey: an empty text clears the key, as the tracker's write-state does" '[ -z "$(record get "$keyed" step)" ]'
record set "$keyed" attempts= >/dev/null 2>&1
check "EmptyAttempts_ReadsZero: an empty attempts is 0, as the tracker reads it" '[ "$(record get "$keyed" attempts)" = 0 ]'
record set "$keyed" gate=none >/dev/null 2>&1
check "GateNone_ReadsNone: a cleared gate reads none, as the tracker's state does" '[ "$(record get "$keyed" gate)" = none ]'
record set "$keyed" last-event="spelt with a dash" >/dev/null 2>&1
check "DashKey_ReadsAsItsUnderscoreKey: a dash in a key reads as an underscore, as write-state takes it" \
  '[ "$(record get "$keyed" last_event)" = "spelt with a dash" ]'

echo "the gate's record: each field reads back after gate:="
gate_record='{"gate":"ambiguity","item":"ignored","message":"Which row owns the retune?","time":"2026-11-15T10:00:00Z","host":"codex","options":[{"label":"Keep both rows","text":"Both rows stay","recommended":true}],"raised_by":"step design","answered_by":"step plan","condition":"ci:down","footer":"gate.sh clear with an option"}'
record set "$keyed" "gate:=$gate_record" >/dev/null 2>&1
while IFS='|' read -r path; do
  check "GateRecord_${path}_ReadsBackAsGiven: the gate's record keeps every field notify.sh writes" \
    '[ "$(record get "$keyed" "gate.$path")" = "$(printf "%s" "$gate_record" | json_value "$path")" ]'
done <<'FIELDS'
message
time
host
options.0.label
raised_by
answered_by
condition
footer
FIELDS
check "GateRecord_ReadsItsNameAsTheGateKey: the gate key reads the record's name" \
  '[ "$(record get "$keyed" gate)" = "$(printf "%s" "$gate_record" | json_value gate)" ]'

echo "refused writes leave the record and the tracker as they were"
refused="$(new_task "Refused writes")"
record set "$refused" step=plan >/dev/null 2>&1
refusal() { # refusal <scenario> <pair>...
  scenario="$1"; shift
  record_before="$(record show "$refused")"; tracker_before="$(tracker "$refused")"
  record set "$refused" "$@" >/dev/null 2>&1; code=$?
  check "${scenario}_ExitsTwo: a write outside the grammar is a usage error" '[ "$code" -eq 2 ]'
  check "${scenario}_LeavesBothStoresAsTheyWere: a refused write reaches neither the record nor the tracker" \
    '[ "$(record show "$refused")" = "$record_before" ] && [ "$(tracker "$refused")" = "$tracker_before" ]'
}
refusal UnknownKey colour=blue
refusal AttemptsNotAWholeNumber attempts=x
refusal RecordPairNotJson "run:=not json"
refusal StatePairBesideRecordPair step=review run.step=review
record set nowhere:1 step=plan >/dev/null 2>&1; code=$?
check "IdNoAdapterOwns_ExitsTwo: an id no adapter owns has no record" '[ "$code" -eq 2 ]'
check "IdNoAdapterOwns_WritesNoRecord: nothing is written for an id no adapter owns" '[ ! -f "$(record path nowhere:1)" ]'

echo "the mirror: the tracker gets each state write first"
mirrored="$(new_task "Mirror")"
record set "$mirrored" step=verify >/dev/null 2>&1
check "DefaultTrackerState_TrackerReadsTheValueSet: with tracker_state labels the tracker takes every state write" '[ "$(state "$mirrored" step)" = verify ]'
tracker_state_is none
record set "$mirrored" step=review >/dev/null 2>&1
check "TrackerStateNone_TrackerKeepsItsValue: with tracker_state none no write reaches the tracker" '[ "$(state "$mirrored" step)" = verify ]'
check "TrackerStateNone_RecordTakesTheWrite: with the mirror off the record still takes the write" '[ "$(record get "$mirrored" step)" = review ]'
tracker_state_is sometimes
record set "$mirrored" step=done >/dev/null 2>&1; code=$?
check "UnknownTrackerState_ExitsTwo: tracker_state is labels or none, anything else is bad config" '[ "$code" -eq 2 ]'
tracker_state_is ""
refusing="$(new_task "Tracker refuses")"
record set "$refusing" step=plan >/dev/null 2>&1
chmod a-w "$(item_file "$refusing")"
record set "$refusing" step=implement >/dev/null 2>&1; code=$?
check "TrackerRefusesTheWrite_FailsIt: a write the tracker did not take fails, as it did before the records" '[ "$code" -ne 0 ]'
check "TrackerRefusesTheWrite_RecordsNothing: the record takes only what the tracker took" '[ "$(record get "$refusing" step)" = plan ]'
record set "$refusing" 'run:={"step":"implement","pid":4242}' >/dev/null 2>&1
check "TrackerRefusesWrites_RecordOnlyPairLands: a record pair never goes to the tracker, so its refusal does not stop it" \
  '[ "$(record get "$refusing" run.pid)" = 4242 ]'
chmod u+w "$(item_file "$refusing")"

echo "the lock: two writers at once both land"
tracker_state_is none
raced="$(new_task "Two writers")"
record set "$raced" step=plan >/dev/null 2>&1
lock_rounds=25
writer() { round=1; while [ "$round" -le "$lock_rounds" ]; do record set "$raced" "$1=$1-$round" >/dev/null 2>&1; round=$((round + 1)); done; }
writer step & writer last_event & wait
check "TwoWritersOfDifferentKeys_BothKeepTheirLastValue: each write merges under the item's lock, so neither loses the other's key" \
  '[ "$(record get "$raced" step)" = "step-$lock_rounds" ] && [ "$(record get "$raced" last_event)" = "last_event-$lock_rounds" ]'
check "TwoWritersOfDifferentKeys_LeaveARecordThatParses: a write replaces the record whole, never in part" \
  'record show "$raced" | python3 -c "import json,sys; json.load(sys.stdin)"'
fresh="$(new_task "Two first writes")"
record set "$fresh" step=plan >/dev/null 2>&1 & record set "$fresh" last_event=first >/dev/null 2>&1 & wait
check "TwoFirstWritesAtOnce_MakeOneRecordWithBoth: the second first write finds the record and merges into it" \
  '[ "$(record get "$fresh" step)" = plan ] && [ "$(record get "$fresh" last_event)" = first ]'
tracker_state_is ""

echo "the seed: an item started before the records"
started="$(new_task "Started before the records")"
"$local_adapter/write-state.sh" "$started" step=implement profile=task-M size=M worktree=wt-1 attempts=2 \
  touches=src/a/**,docs/b.md changes=lib/c.sh base=plan/sandbox held_by=local:task/9 held_reason="same row" \
  gate=ambiguity gate_from=design answered=plan-approval asked="Approve the plan?" answer=Approved \
  answered_at=2026-11-14T08:00:00Z answer_pending=next pr=https://example.invalid/pull/8 pr_host=codex
env FLOW_MACHINE=gamma "$plugin/scripts/state.sh" set "$started" last_event=resumed >/dev/null 2>&1
seeded_keys="$("$local_adapter/read.sh" "$started" | python3 -c 'import json,sys; print(" ".join(key for key in json.load(sys.stdin)["state"] if key != "last_event"))')"
check "FirstWriteOfAStartedItem_CopiesTheTrackersStateKeys: the record starts from the tracker's state, so nothing in flight is lost" \
  '[ -n "$seeded_keys" ] && for key in $seeded_keys; do [ "$(record get "$started" "$key" | canonical)" = "$(state "$started" "$key" | canonical)" ] || { echo "$key differs"; exit 1; }; done'
check "FirstWriteOfAStartedItem_ClaimsItForThisMachine: an item with a step was started here" '[ "$(record get "$started" claim.machine)" = gamma ]'
"$local_adapter/write-state.sh" "$started" step=review
check "LaterTrackerChange_DoesNotReachTheRecord: once a record exists it wins and is never compared again" '[ "$(record get "$started" step)" = implement ]'
unrecorded="$(new_task "Never written")"
check "ItemWithNoRecord_GetPrintsNothing: a read never seeds a record" '[ -z "$(record get "$unrecorded" step)" ] && [ ! -f "$(record path "$unrecorded")" ]'

echo "take and archive"
taken="$(new_task "Taken here")"
take alpha "$taken" >/dev/null 2>&1
check "TakeOfAnUnheldItem_RecordsThisMachine: take_item makes this machine the item's holder" '[ "$(record get "$taken" claim.machine)" = alpha ]'
take beta "$taken" >/dev/null 2>&1
check "TakeOfAnItemAnotherMachineHolds_KeepsThatMachine: a take never moves a hold from another machine" '[ "$(record get "$taken" claim.machine)" = alpha ]'
archived="$(new_task "Archived")"
record set "$archived" last_event=finished >/dev/null 2>&1
record archive "$archived" >/dev/null 2>&1
check "Archive_MovesTheRecordToClosed: an archived record leaves the open ones and is kept under closed/" \
  '[ ! -f "$(record path "$archived")" ] && [ -f "$(closed_record "$archived")" ]'
record set "$archived" last_event=reopened >/dev/null 2>&1
check "WriteAfterArchive_StartsANewRecord: a write to an archived item starts an open record again" '[ "$(record get "$archived" last_event)" = reopened ]'
record archive "$unrecorded" >/dev/null 2>&1; code=$?
check "ArchiveWithNoRecord_DoesNothing: there is nothing to move" '[ "$code" -eq 0 ] && [ ! -f "$(closed_record "$unrecorded")" ]'
held="$(new_task "Held elsewhere")"
take beta "$held" >/dev/null 2>&1
env FLOW_MACHINE=alpha "$plugin/scripts/state.sh" archive "$held" >/dev/null 2>&1; code=$?
check "ArchiveOfARecordAnotherMachineHolds_ExitsOne: only the holder's machine archives a record" '[ "$code" -eq 1 ]'
check "ArchiveOfARecordAnotherMachineHolds_KeepsTheRecord: a refused archive moves nothing" '[ -f "$(record path "$held")" ] && [ ! -f "$(closed_record "$held")" ]'

echo "a caller's stdin"
looped="$(new_task "Loop around a write")"
loop_input="$(printf 'first\nsecond\nthird')"
printf '%s\n' "$loop_input" | while read -r event; do record set "$looped" "last_event=$event" >/dev/null 2>&1; echo "$event"; done > "$work/loop.out"
check "WhileReadLoopAroundSet_KeepsEveryLine: a write reads no stdin of its caller, so the loop sees all its input" \
  '[ "$(cat "$work/loop.out")" = "$loop_input" ]'

[ "$fails" -eq 0 ] && { echo "state: ok"; exit 0; }
echo "state: $fails failed"; exit 1
