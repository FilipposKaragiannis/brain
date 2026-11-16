#!/bin/sh
# state-views.sh: what the flow record renders and how it starts and ends, on the local adapter in
# a throwaway repo. A write renders the run file, the gate file and the claim's step only when it
# names their fact; the first write seeds from the tracker and this machine's gate and run files;
# take (a next.sh start too) and archive (a release of a closed item too); and the record equals
# the tracker's state after next, advance, a gate and a hold.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"

echo "views: a write renders the run file, the gate file and the claim's step it names"
ran="$(new_task "Run view")"
record set "$ran" "run:=$run_record" >/dev/null 2>&1
check "RunObject_WritesTheRunFileWithItsFields: the run file reads as next.sh wrote it, with the item's id" \
  '[ "$(canonical < "$(run_file "$ran")")" = "$(printf "%s" "$run_record" | with_item "$ran")" ]'
record set "$ran" run.step=sync >/dev/null 2>&1
check "RunStep_ChangesTheRunFilesStep: a run that moves to sync shows it in the run file" '[ "$(json_value step < "$(run_file "$ran")")" = sync ]'
record set "$ran" "run:=null" >/dev/null 2>&1
check "RunNull_RemovesTheRunFile: a run that ended leaves no run file" '[ ! -f "$(run_file "$ran")" ]'
hand_ran="$(new_task "Hand-made run file")"
mkdir -p .flow/runs && printf '%s' "$run_record" > "$(run_file "$hand_ran")"
record set "$hand_ran" "run:=null" >/dev/null 2>&1
check "RunNullWithNoRunRecorded_RemovesAHandMadeRunFile: ending the run removes its file whether or not the record had one" \
  '[ ! -f "$(run_file "$hand_ran")" ]'
printf '%s' "$run_record" > "$(run_file "$hand_ran")"
record set "$hand_ran" step=review >/dev/null 2>&1
check "Step_LeavesAHandMadeRunFileAlone: a write that does not name the run does not touch its file" \
  '[ "$(cat "$(run_file "$hand_ran")")" = "$run_record" ]'
record set "$ran" "run:=$run_record" >/dev/null 2>&1; rm -f "$(run_file "$ran")"
record set "$ran" step=review >/dev/null 2>&1
check "StepAfterTheRunFileWentByHand_DoesNotBringItBack: only a write of the run makes its file" '[ ! -f "$(run_file "$ran")" ]'
gated="$(new_task "Gate view")"
record set "$gated" "gate:=$gate_record" >/dev/null 2>&1
check "GateObject_WritesTheGateFileWithNotifysFields: the gate file reads as notify.sh wrote it, with the item's id" \
  '[ "$(canonical < "$(gate_file "$gated")")" = "$(printf "%s" "$gate_record" | with_item "$gated")" ]'
record set "$gated" gate=none >/dev/null 2>&1
check "GateNone_RemovesTheGateFile: a cleared gate leaves no gate file" '[ ! -f "$(gate_file "$gated")" ]'
record set "$gated" "gate:=$gate_record" >/dev/null 2>&1; record set "$gated" gate= >/dev/null 2>&1
check "EmptyGate_RemovesTheGateFile: an empty gate clears it as none does" '[ ! -f "$(gate_file "$gated")" ]'
named_gate="$(new_task "Gate named only")"
record set "$named_gate" gate=plan-approval gate_from=plan >/dev/null 2>&1
check "GateName_WritesNoGateFile: the gate file is notify.sh's record, which a gate name alone does not carry" '[ ! -f "$(gate_file "$named_gate")" ]'
mkdir -p .flow/gates && printf '%s' "$gate_record" > "$(gate_file "$named_gate")"
record set "$named_gate" last_event=reminded >/dev/null 2>&1
check "LastEvent_LeavesAHandMadeGateFileAlone: a write that does not name the gate does not touch its file" \
  '[ "$(cat "$(gate_file "$named_gate")")" = "$gate_record" ]'
claimed="$(new_task "Claim view")"
"$plugin/scripts/steward.sh" claim "$claimed" >/dev/null 2>&1
record set "$claimed" step=implement >/dev/null 2>&1
check "StepOfAClaimedItem_IsTheClaimsStep: the worktree's claim follows the item's step" '[ "$(claim_step "$claimed")" = implement ]'
record set "$claimed" "run:=$run_record" >/dev/null 2>&1; record set "$claimed" run.step=sync >/dev/null 2>&1
check "RunStepOfAClaimedItem_IsTheClaimsStep: the step the run is on is the claim's step" '[ "$(claim_step "$claimed")" = sync ]'
unclaimed="$(new_task "No claim view")"
record set "$unclaimed" step=implement >/dev/null 2>&1
check "StepOfAnUnclaimedItem_MakesNoClaimFile: only a claimed worktree carries the step" '[ -z "$("$plugin/scripts/steward.sh" find "$unclaimed")" ]'

echo "the seed: an item started before the records"
started="$(new_task "Started before the records")"
"$local_adapter/write-state.sh" "$started" step=implement profile=task-M size=M worktree=wt-1 attempts=2 \
  touches=src/a/**,docs/b.md changes=lib/c.sh base=plan/sandbox held_by=local:task/9 held_reason="same row" \
  gate=ambiguity gate_from=design answered=plan-approval asked="Approve the plan?" answer=Approved \
  answered_at=2026-11-14T08:00:00Z answer_pending=next pr=https://example.invalid/pull/8 pr_host=codex
started_gate_file="$(printf '%s' "$gate_record" | with_item "$started")"; started_run_file="$(printf '%s' "$run_record" | with_item "$started")"
printf '%s' "$started_gate_file" > "$(gate_file "$started")"; printf '%s' "$started_run_file" > "$(run_file "$started")"
env FLOW_MACHINE=gamma "$plugin/scripts/state.sh" set "$started" last_event=resumed >/dev/null 2>&1
for key in step profile size worktree attempts touches changes base held_by held_reason gate gate_from answered asked answer answered_at answer_pending pr pr_host; do
  check "FirstWriteOfAStartedItem_Copies_${key}: the record starts from the tracker's state, so nothing in flight is lost" \
    '[ "$(record get "$started" "$key" | canonical)" = "$(state "$started" "$key" | canonical)" ]'
done
check "FirstWriteOfAStartedItem_ClaimsItForThisMachine: an item with a step was started here" '[ "$(record get "$started" claim.machine)" = gamma ]'
check "FirstWriteOfAStartedItem_TakesTheGateFilesOptions: the open gate's options outlive the move to the record" \
  '[ "$(record get "$started" gate.options.0.label)" = "$(printf "%s" "$gate_record" | json_value options.0.label)" ]'
check "FirstWriteOfAStartedItem_TakesTheRunFile: the run in flight outlives the move to the record" \
  '[ "$(record get "$started" run.pid)" = "$(printf "%s" "$run_record" | json_value pid)" ]'
check "FirstWriteOfAStartedItem_LeavesTheGateFileAsItWas: the seed renders no view" '[ "$(cat "$(gate_file "$started")")" = "$started_gate_file" ]'
check "FirstWriteOfAStartedItem_LeavesTheRunFileAsItWas: the seed renders no view" '[ "$(cat "$(run_file "$started")")" = "$started_run_file" ]'
other_gate="$(new_task "Gate file of another gate")"
"$local_adapter/write-state.sh" "$other_gate" step=plan gate=plan-approval
printf '%s' "$gate_record" > "$(gate_file "$other_gate")"
record set "$other_gate" last_event=resumed >/dev/null 2>&1
check "GateFileOfAnotherGate_StaysOutOfTheSeed: the tracker's open gate wins over a gate file left from another one" \
  '[ -z "$(record get "$other_gate" gate.options)" ]'
"$local_adapter/write-state.sh" "$started" step=review
check "LaterTrackerChange_DoesNotReachTheRecord: once a record exists it wins and is never compared again" '[ "$(record get "$started" step)" = implement ]'
unrecorded="$(new_task "Never written")"
check "ItemWithNoRecord_GetPrintsNothing: an item never written has no value to read" '[ -z "$(record get "$unrecorded" step)" ]'
check "ItemWithNoRecord_GetSeedsNoRecord: a read never seeds a record" '[ ! -f "$(record path "$unrecorded")" ]'

echo "take and archive"
taken="$(new_task "Taken here")"
take alpha "$taken" >/dev/null 2>&1
check "TakeOfAnUnheldItem_RecordsThisMachine: take_item makes this machine the item's holder" '[ "$(record get "$taken" claim.machine)" = alpha ]'
take beta "$taken" >/dev/null 2>&1
check "TakeOfAnItemAnotherMachineHolds_KeepsThatMachine: a take never moves a hold from another machine" '[ "$(record get "$taken" claim.machine)" = alpha ]'
started_here="$(new_task "Started by next")"
record set "$started_here" last_event=filed >/dev/null 2>&1
env FLOW_MACHINE=alpha "$plugin/scripts/next.sh" "$started_here" >/dev/null 2>&1
check "NextStartOfARecordedItem_RecordsTheStartingMachineAsTheHolder: starting an item takes it for the machine that started it" \
  '[ "$(record get "$started_here" claim.machine)" = alpha ]'
archived="$(new_task "Archived")"
record set "$archived" last_event=finished >/dev/null 2>&1
record archive "$archived" >/dev/null 2>&1
check "Archive_LeavesNoOpenRecord: an archived record leaves the open ones" '[ ! -f "$(record path "$archived")" ]'
check "Archive_KeepsTheRecordUnderClosed: an archived record is kept, not deleted" '[ -f "$(closed_record "$archived")" ]'
record set "$archived" last_event=reopened >/dev/null 2>&1
check "WriteAfterArchive_StartsANewRecord: a write to an archived item starts an open record again" '[ "$(record get "$archived" last_event)" = reopened ]'
record archive "$unrecorded" >/dev/null 2>&1; code=$?
check "ArchiveWithNoRecord_ExitsZero: there is nothing to move, which is not a refusal" '[ "$code" -eq 0 ]'
check "ArchiveWithNoRecord_MovesNothingToClosed: an item with no record leaves nothing under closed/" '[ ! -f "$(closed_record "$unrecorded")" ]'
held="$(new_task "Held elsewhere")"
take beta "$held" >/dev/null 2>&1
env FLOW_MACHINE=alpha "$plugin/scripts/state.sh" archive "$held" >/dev/null 2>&1; code=$?
check "ArchiveOfARecordAnotherMachineHolds_ExitsOne: only the holder's machine archives a record" '[ "$code" -eq 1 ]'
check "ArchiveOfARecordAnotherMachineHolds_KeepsTheOpenRecord: a refused archive moves nothing" '[ -f "$(record path "$held")" ]'
check "ArchiveOfARecordAnotherMachineHolds_PutsNothingUnderClosed: a refused archive moves nothing" '[ ! -f "$(closed_record "$held")" ]'
released="$(new_task "Released when closed")"
released_worktree="$("$plugin/scripts/steward.sh" claim "$released" 2>/dev/null)"
"$local_adapter/close.sh" "$released" >/dev/null
"$plugin/scripts/steward.sh" release "$released_worktree" >/dev/null 2>&1
check "ReleaseOfAClosedItem_LeavesNoOpenRecord: a closed item's record leaves the open ones with its worktree" '[ ! -f "$(record path "$released")" ]'
check "ReleaseOfAClosedItem_KeepsItsRecordUnderClosed: a released item's record is archived, not deleted" '[ -f "$(closed_record "$released")" ]'

echo "parity: the record equals the tracker's state after the flow's own writes"
paired="$(new_task "Parity")"
paired_start="$("$plugin/scripts/next.sh" "$paired" --json 2>/dev/null)"
paired_step="$(printf '%s' "$paired_start" | json_value step)"
printf '{"status":"done","summary":"done","touches":["src/a/**"]}\n' > "$(printf '%s' "$paired_start" | json_value reports)/$paired_step.json"
"$plugin/scripts/advance.sh" "$paired" >/dev/null 2>&1
check "NextAndAdvance_RecordEqualsTheTrackersState: a started and advanced item reads the same in both stores" 'first_key_differing_from_tracker "$paired"'
"$plugin/scripts/gate.sh" raise "$paired" ambiguity "Which row owns the retune?" >/dev/null 2>&1
check "GateRaise_RecordEqualsTheTrackersState: a raised gate reads the same in both stores" 'first_key_differing_from_tracker "$paired"'
"$plugin/scripts/gate.sh" clear "$paired" "Keep both rows" >/dev/null 2>&1
check "GateClear_RecordEqualsTheTrackersState: a cleared gate and its answer read the same in both stores" 'first_key_differing_from_tracker "$paired"'

echo "parity of a hold"
holder="$(new_task "Holder")"; waiter="$(new_task "Waiter")"
"$plugin/scripts/hold.sh" set "$waiter" "$holder" "same retune of the row owner" >/dev/null 2>&1
check "HoldSet_RecordEqualsTheTrackersState: a hold reads the same in both stores" 'first_key_differing_from_tracker "$waiter"'
"$plugin/scripts/hold.sh" clear "$waiter" "holder merged" >/dev/null 2>&1
check "HoldClear_RecordEqualsTheTrackersState: a lifted hold reads the same in both stores" 'first_key_differing_from_tracker "$waiter"'

[ "$fails" -eq 0 ] && { echo "state-views: ok"; exit 0; }
echo "state-views: $fails failed"; exit 1
