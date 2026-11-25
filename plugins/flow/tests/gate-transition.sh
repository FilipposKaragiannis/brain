#!/bin/sh
# gate-transition.sh: an item never moves past a human gate the tracker has not recorded, and a
# state write advance.sh cannot make leaves the step to apply again, on the local adapter with a
# stand-in write-state that refuses, dies on or takes and then fails the write that records a gate
# or refuses any write with a named pair, a stand-in comment that refuses or kills gate.sh after
# the gate write and a stand-in notify.sh that kills advance.sh once a gate is raised, and on the
# GitHub and Jira adapters with their fakes, where the labels can land and the state write after
# them fail. advance.sh moves the step and records the gate in one tracker write; a refused or
# killed write leaves the item at its step with its run, exits 1 with the reason, and a retry
# raises the gate once. A gate write the tracker takes but fails on every try stands, with the
# whole transition in the flow record. A refused write of the touches, the plan's changes or hold, a failed step's attempt, a
# re-size or the step done keeps the run, and the retry applies the step as the first try would
# have. A failing notifier or comment leaves the gate standing and says so. next.sh runs no step
# for an item with a gate record on this host that its tracker does not show. Under tracker_state
# none a failed record write raises nothing, whatever gate the tracker's labels show. Every repo
# whose tracker refuses or fails a write sets tracker_state labels, the one mode that writes it.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
unset FLOW_TRACKER_STATE

stubbed="$work/plugin-stubbed"; cp -R "$plugin" "$stubbed"; rm -rf "$stubbed/evals/results"
mv "$stubbed/adapters/local/write-state.sh" "$stubbed/adapters/local/write-state-tracker.sh"
GATE_WRITE_MODE="$work/gate-write-mode"; REFUSED_PAIR="$work/refused-pair"; export GATE_WRITE_MODE REFUSED_PAIR
cat > "$stubbed/adapters/local/write-state.sh" <<'STUB'
#!/bin/sh
refused_prefix="$(cat "$REFUSED_PAIR" 2>/dev/null)"
for pair in "$@"; do
  if [ -n "$refused_prefix" ]; then
    case "$pair" in "$refused_prefix"*) echo "flow: the tracker refused the write: API rate limit exceeded" >&2; exit 1 ;; esac
  fi
  case "$pair" in
    gate=|gate=none) ;;
    gate=*)
      case "$(cat "$GATE_WRITE_MODE" 2>/dev/null)" in
        refused) echo "flow: the tracker refused the write: API rate limit exceeded" >&2; exit 1 ;;
        killed) kill -9 "$$" ;;
        landed) "$(dirname "$0")/write-state-tracker.sh" "$@"; echo "flow: the tracker took the labels, then refused the state write: API rate limit exceeded" >&2; exit 1 ;;
      esac ;;
  esac
done
exec "$(dirname "$0")/write-state-tracker.sh" "$@"
STUB
chmod +x "$stubbed/adapters/local/write-state.sh"
GATE_COMMENT_MODE="$work/gate-comment-mode"; export GATE_COMMENT_MODE
mv "$stubbed/adapters/local/comment.sh" "$stubbed/adapters/local/comment-tracker.sh"
cat > "$stubbed/adapters/local/comment.sh" <<'STUB'
#!/bin/sh
case "$*" in
  *"**Gate: "*)
    case "$(cat "$GATE_COMMENT_MODE" 2>/dev/null)" in
      refused) echo "flow: the tracker refused the comment" >&2; exit 1 ;;
      killed) kill -9 "$PPID"; exit 1 ;;
    esac ;;
esac
exec "$(dirname "$0")/comment-tracker.sh" "$@"
STUB
chmod +x "$stubbed/adapters/local/comment.sh"
ADVANCE_KILL_SWITCH="$work/kill-advance-after-notify"; export ADVANCE_KILL_SWITCH
mv "$stubbed/scripts/notify.sh" "$stubbed/scripts/notify-delivered.sh"
cat > "$stubbed/scripts/notify.sh" <<'STUB'
#!/bin/sh
"$(dirname "$0")/notify-delivered.sh" "$@"; delivered=$?
[ ! -e "$ADVANCE_KILL_SWITCH" ] || kill -9 "$(ps -o ppid= -p "$PPID" | tr -d ' ')"
exit "$delivered"
STUB
chmod +x "$stubbed/scripts/notify.sh"
FLOW_PLUGIN="$stubbed"; export FLOW_PLUGIN
local_adapter="$stubbed/adapters/local"

export FAKE_GH_DIR="$work/gh" FLOW_GH_RETRY_WAIT="0 0"
mkdir -p "$FAKE_GH_DIR" "$work/github" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$plugin/tests/fake-gh.sh" "$work/github/gh"
PATH="$work/github:$PATH"; export PATH

gate_wait_status=4
once=1
one_refusal=1
rate_limited=429
PLAN_SUMMARY="Plan: one module, two steps."
item_file() { printf '.flow/items/task/%s.md' "${1##*/}"; }
gate_comments() { grep -c '\*\*Gate: plan-approval\*\*' "$(item_file "$1")"; }
gate_record() { printf '.flow/gates/%s.json' "$(slug "$1")"; }
gate_events() { grep -cF "$(printf '\t%s\tplan-approval\t' "$1")" .flow/events.log; }
reports_of() { state "$1" run.reports; }
# task_at <title> <step>: a new task-M task of size M with its run at <step> started.
task_at() {
  task_at_item="$(new_task "$1")"
  "$local_adapter/write-state.sh" "$task_at_item" "step=$2" profile=task-M size=M
  "$stubbed/scripts/next.sh" "$task_at_item" >/dev/null 2>&1
  printf '%s' "$task_at_item"
}
# result_of <item> <step> <json>: writes the result of the item's run in flight.
result_of() { printf '%s\n' "$3" > "$(reports_of "$1")/$2.json"; }
planned_task() {
  planned="$(task_at "$1" plan)"
  result_of "$planned" plan "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}"
  printf '%s' "$planned"
}
state_or_empty() { state "$1" "$2"; }
advance() { "$stubbed/scripts/advance.sh" "$1" > "$work/advance.out" 2> "$work/advance.err"; }
# advance_refusing <pair prefix> <item>: advance.sh on the item while the tracker refuses any write
# with a pair that starts with the prefix.
advance_refusing() { printf '%s' "$1" > "$REFUSED_PAIR"; advance "$2"; refused_code=$?; rm -f "$REFUSED_PAIR"; return "$refused_code"; }
# mirrored_repo <name>: new_repo under tracker_state labels, so the flow's state writes reach the
# tracker and its refusals reach the flow.
mirrored_repo() { new_repo "$1" && printf 'tracker_state: labels\n' >> .flow/config.yaml; }

echo "gate transition: the tracker refuses the gate write"
mirrored_repo refused
refused="$(planned_task "Refused gate")"; refused_reports="$(reports_of "$refused")"
echo refused > "$GATE_WRITE_MODE"
advance "$refused"; refused_code=$?
check "RefusedGateWrite_ExitsWithAFailure: the caller must not report success" \
  '[ "$refused_code" -ne 0 ]'
check "RefusedGateWrite_DoesNotExitWithTheGateWaitStatus: the caller must not report the item as waiting at a gate" \
  '[ "$refused_code" -ne "$gate_wait_status" ]'
check "RefusedGateWrite_NamesTheTrackersReason: the owner reads why no gate was raised" \
  'grep -q "rate limit" "$work/advance.err"'
check "RefusedGateWrite_NamesTheGate: the owner reads which gate the retry raises" \
  'grep -q "plan-approval" "$work/advance.err"'
check "RefusedGateWrite_NamesTheItem: the owner reads where the retry raises the gate" \
  'grep -qF "$refused" "$work/advance.err"'
check "RefusedGateWrite_KeepsTheItemAtThePlanStep: no reader sees the step past an unrecorded gate" \
  '[ "$(state "$refused" step)" = plan ]'
check "RefusedGateWrite_RecordsNoGateInTheState: the tracker holds neither half of the transition" \
  '[ "$(state "$refused" gate)" = none ]'
check "RefusedGateWrite_KeepsTheRun: advance.sh run again picks the gate transition up" \
  '[ -n "$(state "$refused" run)" ]'
check "RefusedGateWrite_RecordsNoGateOnThisHost: the owner is not asked a question the tracker does not hold" \
  '[ ! -e "$(gate_record "$refused")" ]'
"$stubbed/scripts/next.sh" "$refused" >/dev/null 2>&1; refused_next_code=$?
check "RefusedGateWrite_NextStartsNoImplementStep: the plan is not approved" \
  '[ ! -e "$refused_reports/brief-implement.md" ]'
check "RefusedGateWrite_NextDoesNotSucceed: the caller is not handed a step to run" \
  '[ "$refused_next_code" -ne 0 ]'

echo "gate transition: a retry after the refusal"
rm -f "$GATE_WRITE_MODE"
advance "$refused"; retry_code=$?
check "RetryAfterARefusedGateWrite_ExitsWithTheGateWaitStatus: the transition the refusal stopped completes" \
  '[ "$retry_code" -eq "$gate_wait_status" ]'
check "RetryAfterARefusedGateWrite_RecordsTheGateInTheState: the item waits at the gate" \
  '[ "$(state "$refused" gate)" = plan-approval ]'
check "RetryAfterARefusedGateWrite_MovesTheItemToTheStepAfterTheGate: the step lands with the gate" \
  '[ "$(state "$refused" step)" = implement ]'
check "RetryAfterARefusedGateWrite_RaisesOneGateComment: the owner is asked once" \
  '[ "$(gate_comments "$refused")" -eq "$once" ]'
check "RetryAfterARefusedGateWrite_LogsOneGateRaise: the board shows one raise of the gate" \
  '[ "$(gate_events "$refused")" -eq "$once" ]'
check "RetryAfterARefusedGateWrite_RecordsThePlanApprovalGate: the record names the gate the owner answers" \
  '[ "$(json_value gate < "$(gate_record "$refused")")" = plan-approval ]'
"$stubbed/scripts/next.sh" "$refused" >/dev/null 2>&1; retry_next_code=$?
check "RetryAfterARefusedGateWrite_NextExitsWithTheGateWaitStatus: implement waits for the approval" \
  '[ "$retry_next_code" -eq "$gate_wait_status" ]'
check "RetryAfterARefusedGateWrite_NextStartsNoImplementStep: the plan is still not approved" \
  '[ ! -e "$refused_reports/brief-implement.md" ]'

echo "gate transition: a refused gate write whose run is gone"
orphaned="$(planned_task "Orphaned gate")"
echo refused > "$GATE_WRITE_MODE"
advance "$orphaned"
rm -f "$GATE_WRITE_MODE"; end_run "$orphaned"
"$stubbed/scripts/next.sh" "$orphaned" >/dev/null 2>&1
check "RefusedGateWriteWithItsRunGone_NextRunsThePlanAgain: the tracker state alone keeps the item before the gate" \
  '[ "$(state "$orphaned" run.step)" = plan ]'

echo "gate transition: the gate write dies"
mirrored_repo killed
killed="$(planned_task "Killed gate")"; killed_reports="$(reports_of "$killed")"
echo killed > "$GATE_WRITE_MODE"
advance "$killed"; killed_code=$?
rm -f "$GATE_WRITE_MODE"
check "KilledGateWrite_ExitsWithAFailure: a write that died recorded nothing" \
  '[ "$killed_code" -ne 0 ]'
check "KilledGateWrite_DoesNotExitWithTheGateWaitStatus: the caller must not report the item as waiting at a gate" \
  '[ "$killed_code" -ne "$gate_wait_status" ]'
check "KilledGateWrite_KeepsTheItemAtThePlanStep: the step and the gate land together or not at all" \
  '[ "$(state "$killed" step)" = plan ]'
check "KilledGateWrite_RecordsNoGateInTheState: the tracker holds neither half of the transition" \
  '[ "$(state "$killed" gate)" = none ]'
check "KilledGateWrite_KeepsTheRun: advance.sh run again picks the gate transition up" \
  '[ -n "$(state "$killed" run)" ]'
"$stubbed/scripts/next.sh" "$killed" >/dev/null 2>&1; killed_next_code=$?
check "KilledGateWrite_NextStartsNoImplementStep: the plan is not approved" \
  '[ ! -e "$killed_reports/brief-implement.md" ]'
check "KilledGateWrite_NextDoesNotSucceed: the caller is not handed a step to run" \
  '[ "$killed_next_code" -ne 0 ]'
advance "$killed"; killed_retry_code=$?
check "RetryAfterAKilledGateWrite_ExitsWithTheGateWaitStatus: the retry completes the transition" \
  '[ "$killed_retry_code" -eq "$gate_wait_status" ]'
check "RetryAfterAKilledGateWrite_RecordsThePlanApprovalGate: the item waits at the gate" \
  '[ "$(state "$killed" gate)" = plan-approval ]'
check "RetryAfterAKilledGateWrite_RaisesOneGateComment: the owner is asked once" \
  '[ "$(gate_comments "$killed")" -eq "$once" ]'
check "RetryAfterAKilledGateWrite_LogsOneGateRaise: the board shows one raise of the gate" \
  '[ "$(gate_events "$killed")" -eq "$once" ]'

echo "gate transition: the gate write lands on the tracker and fails on every try"
mirror_lags="$(planned_task "Mirror lags")"
echo landed > "$GATE_WRITE_MODE"
advance "$mirror_lags"
# shellcheck disable=SC2034 # the check's condition reads it
mirror_lags_code=$?
rm -f "$GATE_WRITE_MODE"
check "GateWriteLandingOnTheTrackerAndFailingOnEveryTry_WaitsAtTheGate: the tracker shows the gate and the record takes it, so it stands" \
  '[ "$mirror_lags_code" -eq "$gate_wait_status" ]'
check "GateWriteLandingOnTheTrackerAndFailingOnEveryTry_RecordsTheStepAfterTheGate: the record wins whole, so a step it lacks would run the plan again" \
  '[ "$(state "$mirror_lags" step)" = implement ]'
check "GateWriteLandingOnTheTrackerAndFailingOnEveryTry_RecordsTheStepTheGateWasRaisedFrom: the answer goes back to the step that asked" \
  '[ "$(state "$mirror_lags" gate_from)" = plan ]'
check "GateWriteLandingOnTheTrackerAndFailingOnEveryTry_SaysTheTrackerLags: the owner learns the tracker is behind the record" \
  'grep "plan-approval" "$work/advance.err" | grep -qi "lag"'

echo "gate transition: gate.sh dies after the gate write"
stopped="$(planned_task "Stopped after the write")"; stopped_reports="$(reports_of "$stopped")"
echo killed > "$GATE_COMMENT_MODE"
advance "$stopped"; stopped_code=$?
rm -f "$GATE_COMMENT_MODE"
check "StopAfterTheGateWrite_ExitsWithAFailure: the raise did not finish" \
  '[ "$stopped_code" -ne 0 ]'
check "StopAfterTheGateWrite_DoesNotExitWithTheGateWaitStatus: the caller must not report the raise as done" \
  '[ "$stopped_code" -ne "$gate_wait_status" ]'
check "StopAfterTheGateWrite_LeavesTheGateInTheState: the item past the plan stays blocked" \
  '[ "$(state "$stopped" gate)" = plan-approval ]'
"$stubbed/scripts/next.sh" "$stopped" >/dev/null 2>&1
check "StopAfterTheGateWrite_NextStartsNoImplementStep: the plan is not approved" \
  '[ ! -e "$stopped_reports/brief-implement.md" ]'
advance "$stopped"; stopped_retry_code=$?
check "RetryAfterAStopAfterTheGateWrite_ExitsWithTheGateWaitStatus: the retry finishes the raise" \
  '[ "$stopped_retry_code" -eq "$gate_wait_status" ]'
check "RetryAfterAStopAfterTheGateWrite_RaisesOneGateComment: the owner is asked once" \
  '[ "$(gate_comments "$stopped")" -eq "$once" ]'
check "RetryAfterAStopAfterTheGateWrite_LogsOneGateRaise: the board shows one raise of the gate" \
  '[ "$(gate_events "$stopped")" -eq "$once" ]'

echo "gate transition: the desktop notification fails"
new_repo notifier
sed -i.bak 's/desktop: false/desktop: true/' .flow/config.yaml && rm -f .flow/config.yaml.bak
mkdir -p "$work/broken" && printf '#!/bin/sh\nexit 1\n' > "$work/broken/osascript" && chmod +x "$work/broken/osascript"
notified="$(planned_task "Notifier down")"
PATH="$work/broken:$PATH" advance "$notified"; notified_code=$?
check "FailingNotifier_StillWaitsAtTheGate: a notification is no part of the gate" \
  '[ "$notified_code" -eq "$gate_wait_status" ]'
check "FailingNotifier_LeavesTheGateInTheState: the tracker keeps the gate" \
  '[ "$(state "$notified" gate)" = plan-approval ]'
check "FailingNotifier_LeavesTheGateRecordOnThisHost: the board still lists the gate" \
  '[ -f "$(gate_record "$notified")" ]'
check "FailingNotifier_IsReported: the owner learns no notification went out" \
  'grep -qi "notif" "$work/advance.err"'

echo "gate transition: the normal path"
new_repo normal
normal="$(planned_task "Normal gate")"
advance "$normal"; normal_code=$?
check "PlanDone_ExitsWithTheGateWaitStatus: the owner approves before implement" \
  '[ "$normal_code" -eq "$gate_wait_status" ]'
check "PlanDone_RecordsThePlanApprovalGate: the tracker shows the gate" \
  '[ "$(state "$normal" gate)" = plan-approval ]'
check "PlanDone_MovesTheItemToImplement: the step after the gate is recorded with it" \
  '[ "$(state "$normal" step)" = implement ]'
check "PlanDone_RaisesOneGateComment: the owner is asked once" \
  '[ "$(gate_comments "$normal")" -eq "$once" ]'

echo "gate transition: the gate comment fails"
new_repo commented
commented="$(planned_task "Comment down")"
echo refused > "$GATE_COMMENT_MODE"
advance "$commented"; commented_code=$?
rm -f "$GATE_COMMENT_MODE"
check "FailingGateComment_StillWaitsAtTheGate: the comment is no part of the gate" \
  '[ "$commented_code" -eq "$gate_wait_status" ]'
check "FailingGateComment_LeavesTheGateInTheState: the tracker keeps the gate" \
  '[ "$(state "$commented" gate)" = plan-approval ]'
check "FailingGateComment_IsReported: the owner learns the comment is missing" \
  'grep "plan-approval" "$work/advance.err" | grep -qi "comment"'

echo "state write: a refused step write after a re-size"
mirrored_repo resized
shrunk="$(task_at "Smaller than planned" design)"
result_of "$shrunk" design '{"status":"done","summary":"Design: one file.","size":"S"}'
advance_refusing step=implement "$shrunk"
check "RefusedStepWriteAfterAResize_KeepsTheRun: advance.sh run again applies the re-size" \
  '[ -n "$(state "$shrunk" run)" ]'
check "RefusedStepWriteAfterAResize_KeepsTheOldSize: no reader sees the new size with the old profile" \
  '[ "$(state "$shrunk" size)" = M ]'
advance "$shrunk"
check "RetryAfterARefusedStepWriteOnAResize_MovesToTheFirstStepOfTheSmallerProfile: the retry runs the profile the re-size chose" \
  '[ "$(state "$shrunk" step)" = implement ]'
check "RetryAfterARefusedStepWriteOnAResize_RecordsTheSmallerProfile: the item goes on as a task-S" \
  '[ "$(state "$shrunk" profile)" = task-S ]'
check "RetryAfterARefusedStepWriteOnAResize_RecordsTheNewSize: the size lands with the step" \
  '[ "$(state "$shrunk" size)" = S ]'

echo "state write: a refused write of a failed step"
failed="$(task_at "Review found a gap" review)"
result_of "$failed" review '{"status":"fail","summary":"Review: a test is missing."}'
advance_refusing attempts= "$failed"
check "RefusedFailWrite_KeepsTheRun: advance.sh run again counts the attempt" \
  '[ -n "$(state "$failed" run)" ]'
advance "$failed"
check "RetryAfterARefusedFailWrite_CountsOneAttempt: the failure counts toward the escalation" \
  '[ "$(state "$failed" attempts)" -eq "$once" ]'
check "RetryAfterARefusedFailWrite_MovesToTheFixStep: the review's gap goes back to implement" \
  '[ "$(state "$failed" step)" = implement ]'

echo "state write: a refused write of the touches"
touched="$(task_at "Touches refused" design)"
result_of "$touched" design '{"status":"done","summary":"Design: the ball.","touches":["src/ball/*"]}'
advance_refusing touches= "$touched"
check "RefusedTouchesWrite_KeepsTheRun: advance.sh run again records the touches" \
  '[ -n "$(state "$touched" run)" ]'
advance "$touched"
check "RetryAfterARefusedTouchesWrite_RecordsTheTouches: the holds read what the step touched" \
  'state_or_empty "$touched" touches | grep -qF "src/ball/*"'

echo "state write: a refused write of the plan's changes"
changed="$(task_at "Changes refused" plan)"
result_of "$changed" plan "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\",\"changes\":[\"src/ball/*\"]}"
advance_refusing changes= "$changed"
check "RefusedChangesWrite_KeepsTheRun: advance.sh run again records the changes" \
  '[ -n "$(state "$changed" run)" ]'
advance "$changed"
check "RetryAfterARefusedChangesWrite_RecordsTheChanges: the holds read what the plan changes" \
  'state_or_empty "$changed" changes | grep -qF "src/ball/*"'

echo "state write: a refused hold"
holder="$(new_task "Holder")"
held="$(task_at "Hold refused" plan)"
result_of "$held" plan "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\",\"hold\":{\"behind\":\"$holder\",\"reason\":\"both change the ball\"}}"
advance_refusing held_by= "$held"
check "RefusedHoldWrite_KeepsTheRun: an item whose hold was not recorded must not go on unheld" \
  '[ -n "$(state "$held" run)" ]'
advance "$held"
check "RetryAfterARefusedHoldWrite_HoldsTheItemBehindItsHolder: the plan's hold lands" \
  '[ "$(state_or_empty "$held" held_by)" = "$holder" ]'

echo "state write: a refused lift of a hold"
lifted="$(task_at "Hold lift refused" plan)"
"$plugin/scripts/state.sh" set "$lifted" "held_by=$holder" "held_reason=an earlier plan"
result_of "$lifted" plan "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}"
advance_refusing held_by= "$lifted"
check "RefusedHoldLift_KeepsTheRun: advance.sh run again lifts the hold" \
  '[ -n "$(state "$lifted" run)" ]'
advance "$lifted"
check "RetryAfterARefusedHoldLift_LiftsTheHold: a plan with no hold leaves the item free" \
  '[ -z "$(state_or_empty "$lifted" held_by)" ]'

echo "state write: a refused write past a gate the step asked and the owner answered"
answered="$(task_at "Asked at the plan" plan)"
result_of "$answered" plan '{"status":"gate","gate":"plan-approval","message":"Approve the plan as it stands?"}'
advance "$answered"
"$stubbed/scripts/gate.sh" clear "$answered" "Approved." >/dev/null 2>&1
"$stubbed/scripts/next.sh" "$answered" >/dev/null 2>&1
result_of "$answered" plan "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}"
advance_refusing step=implement "$answered"
check "RefusedWritePastAnAnsweredGate_KeepsTheRun: advance.sh run again moves the item on" \
  '[ -n "$(state "$answered" run)" ]'
advance "$answered"
check "RetryAfterARefusedWritePastAnAnsweredGate_DoesNotAskTheGateAgain: the owner answered it at the step" \
  '[ "$(state "$answered" gate)" = none ]'
check "RetryAfterARefusedWritePastAnAnsweredGate_MovesToImplement: the answer stands" \
  '[ "$(state "$answered" step)" = implement ]'

echo "state write: advance.sh dies once a gate the step asked is raised"
asked="$(task_at "Killed after the ask" plan)"
result_of "$asked" plan '{"status":"gate","gate":"plan-approval","message":"Approve the plan as it stands?"}'
: > "$ADVANCE_KILL_SWITCH"; { advance "$asked"; } 2>/dev/null; rm -f "$ADVANCE_KILL_SWITCH"
"$stubbed/scripts/gate.sh" clear "$asked" "Approved." >/dev/null 2>&1
"$stubbed/scripts/next.sh" "$asked" >/dev/null 2>&1
result_of "$asked" plan "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}"
advance "$asked"
check "StopAfterAnAskedGateIsRaised_DoesNotAskTheGateAgainOnceAnswered: the ask was recorded before the raise" \
  '[ "$(state "$asked" gate)" = none ]'

echo "state write: a refused write of the step done after an epic's closeout"
closed_epic="$("$local_adapter/create.sh" epic "Closeout refused" --body x)"
"$local_adapter/write-state.sh" "$closed_epic" step=closeout profile=epic
"$stubbed/scripts/next.sh" "$closed_epic" >/dev/null 2>&1
result_of "$closed_epic" closeout '{"status":"done","summary":"Every acceptance line is proven."}'
advance_refusing step=done "$closed_epic"
check "RefusedDoneWriteAfterAClosedEpic_KeepsTheRun: advance.sh run again records the epic done" \
  '[ -n "$(state "$closed_epic" run)" ]'
advance "$closed_epic"
check "RetryAfterARefusedDoneWriteAfterAClosedEpic_RecordsTheEpicDone: the state agrees with the closed epic" \
  '[ "$(state "$closed_epic" step)" = done ]'

echo "state write: a refused write of the step done with nothing to merge"
mirrored_repo signed-off
signed_off="$("$local_adapter/create.sh" bug "Owner sign-off with no code" --size S --body "$body")"
"$local_adapter/write-state.sh" "$signed_off" step=pr profile=bugfix
"$stubbed/scripts/next.sh" "$signed_off" >/dev/null 2>&1
result_of "$signed_off" pr '{"status":"done","summary":"No PR opened: nothing to commit."}'
advance_refusing step=done "$signed_off"
check "RefusedDoneWriteWithNothingToMerge_KeepsTheRun: advance.sh run again records the item done" \
  '[ -n "$(state "$signed_off" run)" ]'
advance "$signed_off"
check "RetryAfterARefusedDoneWriteWithNothingToMerge_RecordsTheItemDone: the state agrees with the closed item" \
  '[ "$(archived_state "$signed_off" step)" = done ]'
check "RetryAfterARefusedDoneWriteWithNothingToMerge_ReleasesTheWorktree: a closed item must not hold a pool worktree" \
  '[ -z "$("$stubbed/scripts/steward.sh" find "$signed_off")" ]'

echo "state write: an auto-approved gate whose step write is refused"
mirrored_repo auto
printf 'auto_gates:\n  plan-approval: M\n' >> .flow/config.yaml
auto="$(planned_task "Auto approved")"
advance_refusing step=implement "$auto"
check "RefusedWritePastAnAutoApprovedGate_KeepsTheRun: advance.sh run again moves the item on" \
  '[ -n "$(state "$auto" run)" ]'
advance "$auto"
check "RetryAfterARefusedWritePastAnAutoApprovedGate_MovesToImplement: the auto-approval stands" \
  '[ "$(state "$auto" step)" = implement ]'

echo "gate transition: a gate record the tracker does not show"
new_repo stray
stray="$(new_task "Stray record")"
"$local_adapter/write-state.sh" "$stray" step=implement profile=task-M size=M
mkdir -p .flow/gates
printf '{"gate": "plan-approval", "item": "%s", "message": "Approve the plan."}' "$stray" > "$(gate_record "$stray")"
"$stubbed/scripts/next.sh" "$stray" > "$work/stray.out" 2> "$work/stray.err"; stray_code=$?
check "GateRecordTheTrackerLacks_StopsNextWithTheGateWaitStatus: the owner was asked, so the step waits for the answer" \
  '[ "$stray_code" -eq "$gate_wait_status" ]'
check "GateRecordTheTrackerLacks_StartsNoRun: no step runs behind the record" \
  '[ -z "$(state "$stray" run)" ]'
check "GateRecordTheTrackerLacks_NamesTheGate: the owner learns which gate holds the item" \
  'grep -q "plan-approval" "$work/stray.err"'
check "GateRecordTheTrackerLacks_NamesTheRecord: the owner learns where the gate is recorded" \
  'grep -qF "$(gate_record "$stray")" "$work/stray.err"'
check "GateRecordTheTrackerLacks_SaysHowToAnswer: the owner learns the command that clears it" \
  'grep -q "gate.sh clear $stray" "$work/stray.err"'
"$stubbed/scripts/next.sh" > "$work/stray-pick.out" 2> "$work/stray-pick.err"; stray_pick_code=$?
check "PickWithAGateRecordTheTrackerLacks_HandsNoStep: the pick passes the item over" \
  '[ "$stray_pick_code" -ne 0 ]'
check "PickWithAGateRecordTheTrackerLacks_StartsNoRun: no step runs behind the record" \
  '[ -z "$(state "$stray" run)" ]'
check "PickWithAGateRecordTheTrackerLacks_NamesTheRecord: the owner learns why the item was passed over" \
  'grep -qF "$(gate_record "$stray")" "$work/stray-pick.err"'

echo "gate transition: a failed record write under tracker_state none, with a stale gate label"
new_repo untracked
printf 'tracker_state: none\n' >> .flow/config.yaml
stale="$(new_task "Stale gate label")"
"$local_adapter/write-state.sh" "$stale" step=plan profile=task-M size=M gate=plan-approval
stale_record="$("$stubbed/scripts/state.sh" path "$stale")"; mkdir -p "$(dirname "$stale_record")"
printf 'not a record\n' > "$stale_record"
"$stubbed/scripts/gate.sh" raise "$stale" plan-approval "Approve the plan." > "$work/stale.out" 2> "$work/stale.err"
# shellcheck disable=SC2034 # the check's condition reads it
stale_code=$?
check "FailedRecordWriteWithAStaleGateLabelUnderNone_DiesUnrecorded: under none the tracker gets no writes, so its label proves nothing" \
  '[ "$stale_code" -ne 0 ] && grep -qF "cannot record the plan-approval gate on $stale" "$work/stale.err"'
check "FailedRecordWriteWithAStaleGateLabelUnderNone_PostsNoGateComment: the owner is not asked a question no record holds" \
  '[ "$(gate_comments "$stale")" -eq 0 ]'

echo "gate transition: GitHub refuses the gate labels"
mirrored_repo github
sed -i.bak 's/^  default: local$/  default: github/' .flow/config.yaml && rm -f .flow/config.yaml.bak
printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/1"}]}\n' > "$FAKE_GH_DIR/issues.json"
planned_issue() {
  issue="$("$stubbed/adapters/$1/create.sh" task "$2" --size M --body "$body")"
  "$stubbed/adapters/$1/write-state.sh" "$issue" step=plan profile=task-M size=M
  "$stubbed/scripts/next.sh" "$issue" >/dev/null 2>&1
  printf '%s' "$issue"
}
tracker_state() { "$stubbed/adapters/$1/read.sh" "$2" | json_value "state.$3"; }
tracked="$(planned_issue github "Tracked gate")"
printf '%s\n' "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}" > "$(reports_of "$tracked")/plan.json"
refused_label_edits=9
printf '%s\nAPI rate limit exceeded\nissue edit\n' "$refused_label_edits" > "$FAKE_GH_DIR/fail"
advance "$tracked"; tracked_code=$?
rm -f "$FAKE_GH_DIR/fail"
check "GitHubRefusedGateLabels_ExitsWithAFailure: the caller must not report success" \
  '[ "$tracked_code" -ne 0 ]'
check "GitHubRefusedGateLabels_DoesNotExitWithTheGateWaitStatus: the caller must not report the item as waiting at a gate" \
  '[ "$tracked_code" -ne "$gate_wait_status" ]'
check "GitHubRefusedGateLabels_KeepsTheIssueAtThePlanStep: no reader sees implement without the gate" \
  '[ "$(tracker_state github "$tracked" step)" = plan ]'
check "GitHubRefusedGateLabels_RecordsNoGateInTheState: the issue holds neither half of the transition" \
  '[ "$(tracker_state github "$tracked" gate)" = none ]'
advance "$tracked"; tracked_retry_code=$?
check "GitHubRetryAfterARefusal_ExitsWithTheGateWaitStatus: the retry completes the transition" \
  '[ "$tracked_retry_code" -eq "$gate_wait_status" ]'
check "GitHubRetryAfterARefusal_MovesTheIssueToImplement: the step lands with the gate" \
  '[ "$(tracker_state github "$tracked" step)" = implement ]'
check "GitHubRetryAfterARefusal_RecordsThePlanApprovalGate: the issue shows the gate" \
  '[ "$(tracker_state github "$tracked" gate)" = plan-approval ]'

echo "gate transition: GitHub takes the gate labels and refuses the state comment"
labelled="$(planned_issue github "Labels landed")"
printf '%s\n' "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}" > "$(reports_of "$labelled")/plan.json"
printf '%s\nAPI rate limit exceeded\nissue edit\nlanded\n' "$one_refusal" > "$FAKE_GH_DIR/fail"
advance "$labelled"; labelled_code=$?
rm -f "$FAKE_GH_DIR/fail"
check "GitHubStateCommentRefusedAfterTheLabels_WaitsAtTheGate: the labels carry the gate, so it stands" \
  '[ "$labelled_code" -eq "$gate_wait_status" ]'
check "GitHubStateCommentRefusedAfterTheLabels_ShowsTheGateOnTheIssue: the issue blocks implement" \
  '[ "$(tracker_state github "$labelled" gate)" = plan-approval ]'
check "GitHubStateCommentRefusedAfterTheLabels_WritesTheGateRecord: the board lists the gate the issue shows" \
  '[ "$(json_value gate < "$(gate_record "$labelled")")" = plan-approval ]'
check "GitHubStateCommentRefusedAfterTheLabels_IsReported: the owner learns the state write failed part way" \
  'grep "plan-approval" "$work/advance.err" | grep -qi "fail"'

echo "gate transition: GitHub refuses the gate comment"
uncommented="$(planned_issue github "Comment refused")"
printf '%s\n' "{\"status\":\"done\",\"summary\":\"$PLAN_SUMMARY\"}" > "$(reports_of "$uncommented")/plan.json"
printf '%s\nAPI rate limit exceeded\nissue comment\n' "$one_refusal" > "$FAKE_GH_DIR/fail"
advance "$uncommented"; uncommented_code=$?
rm -f "$FAKE_GH_DIR/fail"
check "GitHubFailingGateComment_StillWaitsAtTheGate: the comment is no part of the gate" \
  '[ "$uncommented_code" -eq "$gate_wait_status" ]'
check "GitHubFailingGateComment_IsReported: the owner learns the comment is missing" \
  'grep "plan-approval" "$work/advance.err" | grep -qi "comment"'

echo "gate transition: Jira refuses the gate labels, then takes them and refuses the state"
mirrored_repo jira
mkdir -p "$work/jira" "$work/jirabin" && cp "$plugin/tests/_fake_jira.py" "$work/jira/"
ln -s "$plugin/tests/fake-jira.sh" "$work/jirabin/curl"
printf '{}\n' > "$work/jira/jira.json"
export FAKE_JIRA_DIR="$work/jira" JIRA_API_TOKEN="gate-transition-token" FLOW_JIRA_RETRY_WAIT="0 0"
PATH="$work/jirabin:$PATH"; export PATH
sed -i.bak 's/^  default: local$/  default: jira/' .flow/config.yaml && rm -f .flow/config.yaml.bak
printf 'jira:\n  site: https://acme.atlassian.net\n  project: WID\n  email: flow@acme.test\n  fields:\n    area: Area\n' >> .flow/config.yaml
jira_refused="$(planned_issue jira "Jira refused")"
printf '%s\n%s\n/rest/api/3/issue/WID-[0-9]*$\n' "$one_refusal" "$rate_limited" > "$FAKE_JIRA_DIR/fail"
"$stubbed/scripts/advance.sh" "$jira_refused" --status done --summary "$PLAN_SUMMARY" > "$work/advance.out" 2> "$work/advance.err"
jira_refused_code=$?
rm -f "$FAKE_JIRA_DIR/fail"
check "JiraRefusedGateLabels_ExitsWithAFailure: the caller must not report success" \
  '[ "$jira_refused_code" -ne 0 ]'
check "JiraRefusedGateLabels_DoesNotExitWithTheGateWaitStatus: the caller must not report the item as waiting at a gate" \
  '[ "$jira_refused_code" -ne "$gate_wait_status" ]'
check "JiraRefusedGateLabels_KeepsTheIssueAtThePlanStep: no reader sees implement without the gate" \
  '[ "$(tracker_state jira "$jira_refused" step)" = plan ]'
jira_labelled="$(planned_issue jira "Jira labels landed")"
printf '%s\n%s\n/properties/\n' "$one_refusal" "$rate_limited" > "$FAKE_JIRA_DIR/fail"
"$stubbed/scripts/advance.sh" "$jira_labelled" --status done --summary "$PLAN_SUMMARY" > "$work/advance.out" 2> "$work/advance.err"
jira_labelled_code=$?
rm -f "$FAKE_JIRA_DIR/fail"
check "JiraStatePropertyRefusedAfterTheLabels_WaitsAtTheGate: the labels carry the gate, so it stands" \
  '[ "$jira_labelled_code" -eq "$gate_wait_status" ]'
check "JiraStatePropertyRefusedAfterTheLabels_ShowsTheGateOnTheIssue: the issue blocks implement" \
  '[ "$(tracker_state jira "$jira_labelled" gate)" = plan-approval ]'

[ "$fails" -eq 0 ] && echo "gate-transition: all passed" || echo "gate-transition: $fails failed"
[ "$fails" -eq 0 ]
