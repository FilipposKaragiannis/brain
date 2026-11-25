#!/bin/sh
# state.sh: the flow record of an item (lib/state.sh, scripts/state.sh), on the local adapter in a
# throwaway repo. Every state key and gate record field reads back, each at its record path, and
# so do pushed and claim.assigned_at; a refused write leaves both stores as they were; the tracker
# gets each state write first unless tracker_state is none; the gate's value rules; where the
# records live; ids of the wrong shape; and a caller's while-read loop keeps its input.
# state-disk.sh has the lock and the disk.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
new_repo records

echo "state keys: each reads back what was set"
keyed="$(new_task "Key round trip")"
while IFS='|' read -r key value expected; do
  record set "$keyed" "$key=$value" >/dev/null 2>&1
  check "Set_${key}_ReadsBackTheValueSet: the record keeps each state key as the tracker does" \
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
answered|feel-test|feel-test
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

echo "the push record: pushed and claim.assigned_at"
pushed_item="$(new_task "Push record")"
record set "$pushed_item" step=plan >/dev/null 2>&1
check "PushedAbsent_ReadsNull: a record no push reached holds pushed as null, because absent objects are null" \
  '[ "$(record show "$pushed_item" | json_value pushed)" = null ]'
record set "$pushed_item" 'pushed:={"status":"needs-you","at":"2026-11-15T12:00:00Z"}' >/dev/null 2>&1
check "PushedObject_ReadsBackItsStatus: pushed:= keeps the status the tracker took, because the record is where the flow reads what the tracker shows" \
  '[ "$(record get "$pushed_item" pushed.status)" = needs-you ]'
take alpha "$pushed_item" >/dev/null 2>&1
record set "$pushed_item" claim.assigned_at=2026-11-15T12:30:00Z >/dev/null 2>&1
check "ClaimAssignedAt_ReadsBackAsGiven: claim.assigned_at= keeps when the flow assigned the item, because the claim holds the assignment the flow made" \
  '[ "$(record get "$pushed_item" claim.assigned_at)" = 2026-11-15T12:30:00Z ]'
unclaimed="$(new_task "Assigned with no claim")"
record set "$unclaimed" "last_event=filed by hand" >/dev/null 2>&1
record set "$unclaimed" claim.assigned_at=2026-11-15T12:30:00Z >/dev/null 2>&1; code=$?
check "AssignedAtWithNoClaim_ExitsTwo: claim.assigned_at= on a record with no claim is a usage error, because only a take makes a claim" \
  '[ "$code" -eq 2 ]'
check "AssignedAtWithNoClaim_MakesNoClaim: the record still has no claim, because an assignment alone never holds the item" \
  '[ "$(record show "$unclaimed" | json_value claim)" = null ]'

echo "refused writes leave the record and the tracker as they were"
refused="$(new_task "Refused writes")"
record set "$refused" step=plan >/dev/null 2>&1
refusal() { # refusal <scenario> <pair>...
  scenario="$1"; shift
  record_before="$(record show "$refused")"; tracker_before="$(tracker "$refused")"
  record set "$refused" "$@" >/dev/null 2>&1; code=$?
  check "${scenario}_ExitsTwo: a write outside the grammar is a usage error" '[ "$code" -eq 2 ]'
  check "${scenario}_LeavesTheRecordAsItWas: a refused write never reaches the record" '[ "$(record show "$refused")" = "$record_before" ]'
  check "${scenario}_LeavesTheTrackerAsItWas: a refused write never reaches the tracker" '[ "$(tracker "$refused")" = "$tracker_before" ]'
}
refusal UnknownKey colour=blue
refusal AttemptsNotAWholeNumber attempts=x
refusal AttemptsInNonAsciiDigits attempts=²
refusal RecordPairNotJson "run:=not json"
refusal RunObjectNotAnObject 'run:=["implement"]'
refusal GateObjectNotAnObject 'gate:="ambiguity"'
refusal GateObjectWithNoName 'gate:={"message":"Which row owns the retune?"}'
refusal GateObjectNamingTheClearedGate 'gate:={"gate":"none","message":"Which row owns the retune?"}'
refusal StatePairBesideRecordPair step=review run.step=review
refusal PushedObjectNotAnObject 'pushed:="in-progress"'
record set nowhere:1 step=plan >/dev/null 2>&1; code=$?
check "IdNoAdapterOwns_ExitsTwo: an id no adapter owns has no record" '[ "$code" -eq 2 ]'
check "IdNoAdapterOwns_WritesNoRecord: nothing is written for an id no adapter owns" '[ ! -f "$(record path nowhere:1)" ]'

echo "the mirror: the tracker gets each state write first"
mirrored="$(new_task "Mirror")"
record set "$mirrored" step=verify >/dev/null 2>&1
check "DefaultTrackerState_TrackerReadsTheValueSet: with tracker_state labels the tracker takes every state write" '[ "$(tracker "$mirrored" step)" = verify ]'
tracker_state_is none
record set "$mirrored" step=review >/dev/null 2>&1
check "TrackerStateNone_TrackerKeepsItsValue: with tracker_state none no write reaches the tracker" '[ "$(tracker "$mirrored" step)" = verify ]'
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

echo "the key map: each tracker key lands at its record path"
mapped="$(new_task "Key map")"
while IFS='|' read -r key value record_path; do
  record set "$mapped" "$key=$value" >/dev/null 2>&1
  check "Set_${key}_LandsAt_${record_path}: the record keeps a tracker key under the schema's own name" \
    '[ "$(record get "$mapped" "$record_path")" = "$value" ]'
done <<'PATHS'
size|S|size_estimate
worktree|wt-3|claim.worktree
held_by|local:task/4|hold.by
held_reason|shares the retune|hold.reason
gate|ambiguity|gate.name
answered|plan-approval|answer.gate
answer_pending|next|answer.pending
pr|https://example.invalid/pull/11|pr.url
pr_host|claude|pr.host
PATHS
record set "$mapped" held_by= held_reason= >/dev/null 2>&1
check "HoldWithEveryFieldEmptied_IsNull: absence is a null hold, never an object of empty fields" '[ "$(record show "$mapped" | json_value hold)" = null ]'
record set "$mapped" step=plan step=verify >/dev/null 2>&1
check "KeyGivenTwice_TakesItsLastValue: the later pair of one write wins, as on the tracker" '[ "$(record get "$mapped" step)" = verify ]'
record set "$mapped" "touches=src/a/**, ,,docs/b.md" >/dev/null 2>&1
check "CommaListWithBlankItems_DropsTheBlanks: a list keeps only the items written" \
  '[ "$(record get "$mapped" touches | canonical)" = "$(printf "%s" "[\"src/a/**\",\"docs/b.md\"]" | canonical)" ]'
list_index_outside_ascii='touches.²'
check "ListIndexInNonAsciiDigits_ReadsAsAPathToNothing: only 0-9 index a list, so any other digit reads no value, as a missing path does" \
  '[ "$(record get "$mapped" "$list_index_outside_ascii"; echo "exit $?")" = "exit 0" ]'

echo "the gate's value rules"
ruled="$(new_task "Gate rules")"
record set "$ruled" "gate:=$gate_record" >/dev/null 2>&1; record set "$ruled" gate_from=design >/dev/null 2>&1
record set "$ruled" gate=ambiguity >/dev/null 2>&1
check "GateNameOfTheOpenGate_KeepsItsRecord: naming the open gate again keeps the question notify.sh wrote" \
  '[ "$(record get "$ruled" gate.message)" = "$(printf "%s" "$gate_record" | json_value message)" ]'
record set "$ruled" gate=plan-approval >/dev/null 2>&1
check "GateNameOfAnotherGate_DropsTheOldGatesRecord: a new gate starts with none of the last gate's options" \
  '[ -z "$(record get "$ruled" gate.options)" ]'
record set "$ruled" "gate:=$gate_record" >/dev/null 2>&1
check "GateObjectOfAnotherGate_StartsWithNoFrom: a gate's origin belongs to that gate only" '[ -z "$(record get "$ruled" gate.from)" ]'
record set "$ruled" gate=none >/dev/null 2>&1; record set "$ruled" gate_from=plan >/dev/null 2>&1
check "GateFromWhileNoGateIsOpen_LeavesTheGateClear: an origin with no gate opens nothing" '[ "$(record get "$ruled" gate)" = none ]'

echo "more refusals"
run_step_on_no_run="$(new_task "Run step with no run")"
record set "$run_step_on_no_run" step=plan >/dev/null 2>&1
record_before="$(record show "$run_step_on_no_run")"
record set "$run_step_on_no_run" run.step=sync >/dev/null 2>&1; code=$?
check "RunStepWithNoRun_ExitsTwo: there is no run to move" '[ "$code" -eq 2 ]'
check "RunStepWithNoRun_WritesNoRunFile: a refused run step makes no run" '[ ! -f "$(run_file "$run_step_on_no_run")" ]'
check "RunStepWithNoRun_LeavesTheRecordAsItWas: a refused write changes nothing" '[ "$(record show "$run_step_on_no_run")" = "$record_before" ]'
record set "$run_step_on_no_run" step >/dev/null 2>&1; code=$?
check "PairWithNoEquals_ExitsTwo: a pair is a key, an equals sign and a value" '[ "$code" -eq 2 ]'
record set "$run_step_on_no_run" >/dev/null 2>&1; code=$?
check "SetWithNoPair_ExitsTwo: a write names at least one pair" '[ "$code" -eq 2 ]'
"$plugin/scripts/state.sh" frobnicate >/dev/null 2>&1; code=$?
check "UnknownCommand_ExitsTwo: state.sh knows get, set, show, path and archive" '[ "$code" -eq 2 ]'

echo "where the records live"
cp .flow/config.yaml "$work/config.saved"
printf 'state:\n  dir: records\n' >> .flow/config.yaml
relative_record="$(record path "$run_step_on_no_run")"; mkdir -p records
check "RelativeStateDir_LivesUnderTheMainWorktree: a relative state.dir is read from the repository root" \
  '[ "$(cd "$(dirname "$relative_record")" && pwd -P)" = "$(cd records && pwd -P)" ]'
rmdir records
cp "$work/config.saved" .flow/config.yaml
unwritable="$(new_task "Unwritable state dir")"
printf 'state:\n  dir: /dev/null/records\n' >> .flow/config.yaml
tracker_before="$(tracker "$unwritable")"
record set "$unwritable" step=plan >/dev/null 2>&1; code=$?
check "StateDirThatCannotBeMade_ExitsTwo: a state.dir that cannot be written is bad config" '[ "$code" -eq 2 ]'
check "StateDirThatCannotBeMade_LeavesTheTrackerAsItWas: bad config is refused before any store is written" \
  '[ "$(tracker "$unwritable")" = "$tracker_before" ]'
cp "$work/config.saved" .flow/config.yaml

read_only_dir="$work/read-only-records"; mkdir -p "$read_only_dir"; chmod a-w "$read_only_dir"
read_only="$(new_task "Read-only state dir")"
printf 'state:\n  dir: %s\n' "$read_only_dir" >> .flow/config.yaml
tracker_before="$(tracker "$read_only")"
record set "$read_only" step=plan >/dev/null 2>&1; code=$?
check "ReadOnlyStateDir_ExitsTwo: a state.dir that is there but cannot be written is bad config" '[ "$code" -eq 2 ]'
check "ReadOnlyStateDir_LeavesTheTrackerAsItWas: bad config is refused before any store is written" \
  '[ "$(tracker "$read_only")" = "$tracker_before" ]'
chmod u+w "$read_only_dir"
cp "$work/config.saved" .flow/config.yaml

echo "ids of the wrong shape"
malformed_id=local:task-3
while IFS='|' read -r scenario arguments; do
  # shellcheck disable=SC2086
  record $arguments >/dev/null 2>&1; code=$?
  check "MalformedId_${scenario}_ExitsTwo: an id its adapter would never make is a usage error" '[ "$code" -eq 2 ]'
done <<IDS
Get|get $malformed_id step
Show|show $malformed_id
Path|path $malformed_id
Archive|archive $malformed_id
Set|set $malformed_id step=plan
SetOfAParentFolder|set local:task/.. step=plan
SetOfAPathOutOfItsKind|set local:../task/1 step=plan
IDS
items_before="$(ls -A .flow/items/task)"
record set "$malformed_id" step=plan >/dev/null 2>&1
check "MalformedId_Set_WritesNoTrackerItem: a refused id reaches no tracker" '[ "$(ls -A .flow/items/task)" = "$items_before" ]'

echo "values that look like options"
optioned="$(new_task "Option-like values")"
while IFS='|' read -r scenario key value; do
  record set "$optioned" "$key=$value" >/dev/null 2>&1
  check "ValueThatLooksLike${scenario}_ReadsBackAsGiven: a pair's value is data, never a word of the command line" \
    '[ "$(record get "$optioned" "$key")" = "$value" ]'
done <<'VALUES'
AnOption|last_event|--seed none
TheEndOfOptions|asked|--
AnOptionWithItsValue|answer|--item=local:task/1
VALUES

echo "a caller's stdin"
looped="$(new_task "Loop around a write")"
loop_input="$(printf 'first\nsecond\nthird')"
printf '%s\n' "$loop_input" | while read -r event; do record set "$looped" "last_event=$event" >/dev/null 2>&1; echo "$event"; done > "$work/loop.out"
check "WhileReadLoopAroundSet_KeepsEveryLine: a write reads no stdin of its caller, so the loop sees all its input" \
  '[ "$(cat "$work/loop.out")" = "$loop_input" ]'

[ "$fails" -eq 0 ] && { echo "state: ok"; exit 0; }
echo "state: $fails failed"; exit 1
