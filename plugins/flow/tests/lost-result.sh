#!/bin/sh
# lost-result.sh: what a step whose session left no result file does next, on the local adapter in
# a throwaway repo, and how long a Claude step waits for the background subagents its session left
# running. A lost result runs the same step again, and its attempts reach the escalation gate; a
# failed result goes to its fix step as before. host_run waits an hour by default, and a ceiling
# the owner exported wins.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

LOST_REVIEW='{"status":"fail","lost":true,"summary":"The review session ended with no result file."}'
FAILED_REVIEW='{"status":"fail","summary":"Two blockers: a bare literal and a widened member."}'
MAX_ATTEMPTS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_attempts"])' "$plugin/profiles.json")"
ONE_HOUR_IN_MILLISECONDS=3600000
OWNER_CEILING_IN_MILLISECONDS=120000
# end_review <item> <result>: the review step set and started on the item, ended with <result>.
# The later attempts start whatever step the item is at, as the loop does.
end_review() {
  "$local_adapter/write-state.sh" "$1" step=review profile=task-S >/dev/null
  start_step "$1"
  step_result "$1" review "$2"
  finish_step "$1"
}

echo "lost result: a review that left no result file runs again"
new_repo lost-review
lost_once="$(new_task "Review whose session was cut short")"
end_review "$lost_once" "$LOST_REVIEW"
check "LostReviewResult_RunsTheReviewAgain: the session found nothing for implement to fix, so the review itself is the step to repeat" \
  '[ "$(state "$lost_once" step)" = review ]'
check "LostReviewResult_CountsTheAttempt: a lost session is still a failed attempt, so it counts toward the gate" \
  '[ "$(state "$lost_once" attempts)" = 1 ]'

echo "lost result: a review lost every time reaches the escalation gate"
lost_always="$(new_task "Review whose session is cut short every time")"
end_review "$lost_always" "$LOST_REVIEW"
attempt=1
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
  start_step "$lost_always"
  step_result "$lost_always" review "$LOST_REVIEW"
  finish_step "$lost_always"
  attempt=$((attempt + 1))
done
check "ReviewLostAtEveryAttempt_RaisesTheEscalationGate: a step that keeps losing its result needs the owner, not an endless loop" \
  '[ "$(state "$lost_always" gate)" = escalation ]'

echo "lost result: a failed review still goes to its fix step"
failed="$(new_task "Review that found blockers")"
end_review "$failed" "$FAILED_REVIEW"
check "FailedReviewResult_GoesToImplement: blockers are work for implement, so the item leaves the review" \
  '[ "$(state "$failed" step)" = implement ]'

echo "background wait: a Claude step waits an hour for its background subagents"
stub_path="$work/stub-claude"; ceiling_log="$work/ceiling.log"; mkdir -p "$stub_path"
printf '#!/bin/sh\nprintf "%%s\\n" "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}" >> "%s"\n' "$ceiling_log" > "$stub_path/claude"
chmod +x "$stub_path/claude"
: > "$ceiling_log"
PATH="$stub_path:$PATH" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS; host_run claude . hi' >/dev/null 2>&1
check "ClaudeStepWithNoCeilingExported_WaitsAnHour: the host's own ten minutes stopped reviewers mid-run, so a step gets an hour" \
  '[ "$(cat "$ceiling_log")" = "$ONE_HOUR_IN_MILLISECONDS" ]'
: > "$ceiling_log"
PATH="$stub_path:$PATH" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$OWNER_CEILING_IN_MILLISECONDS" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' >/dev/null 2>&1
check "ClaudeStepWithACeilingExported_KeepsTheOwnersCeiling: the owner's own setting wins over the default" \
  '[ "$(cat "$ceiling_log")" = "$OWNER_CEILING_IN_MILLISECONDS" ]'

echo "lost-result: $fails failure(s)"
[ "$fails" -eq 0 ]
