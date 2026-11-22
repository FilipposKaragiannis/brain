#!/bin/sh
# lost-result.sh: tests for a step whose session left no result file, on the local adapter in a
# throwaway repo, and for how long a Claude step waits for its background subagents.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

FAILED_REVIEW='{"status":"fail","summary":"Two blockers: a bare literal and a widened member."}'
MAX_ATTEMPTS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_attempts"])' "$plugin/profiles.json")"
DEFAULT_CEILING_IN_MILLISECONDS="$(sh -c '. "$FLOW_PLUGIN/lib/host.sh" && printf %s "$HOST_BACKGROUND_WAIT_MILLISECONDS"')"
OWNER_CEILING_IN_MILLISECONDS=120000
ONE_SESSION=1
fake_claude_folder="$work/fake-claude"
# set_at_review <item>: the item's state set to the review step of the small task profile.
set_at_review() { "$local_adapter/write-state.sh" "$1" step=review profile=task-S >/dev/null; }
# run_silent_sessions <item> <steps>: the unattended loop on the item for <steps> steps, each on the
# offline claude, which writes no result file.
run_silent_sessions() { "$plugin/templates/run-unattended.sh" claude "$1" --max-steps "$2" >/dev/null 2>&1; }
# ceiling_seen_by_claude [arguments for the env command]: the background wait ceiling a Claude
# session that host_run starts reads, printed back by a fake claude.
ceiling_seen_by_claude() {
  env "$@" PATH="$fake_claude_folder:$PATH" sh -c '. "$FLOW_PLUGIN/lib/host.sh" && host_run claude . hi' 2>/dev/null
}

echo "lost result: a review whose session left no result file"
new_repo lost-review
lost_once="$(new_task "Review whose session was cut short")"
set_at_review "$lost_once"
run_silent_sessions "$lost_once" "$ONE_SESSION"
check "SilentReviewSession_RunsTheReviewAgain: the session found nothing for implement to fix, so the review itself is the step to repeat" \
  '[ "$(state "$lost_once" step)" = review ]'
check "SilentReviewSession_CountsTheAttempt: a lost session is still a failed attempt, so it counts toward the gate" \
  '[ "$(state "$lost_once" attempts)" = "$ONE_SESSION" ]'

echo "lost result: a review lost at every attempt"
lost_always="$(new_task "Review whose session is cut short every time")"
set_at_review "$lost_always"
run_silent_sessions "$lost_always" "$MAX_ATTEMPTS"
check "ReviewLostAtEveryAttempt_RaisesTheEscalationGate: a step that keeps losing its result needs the owner, not an endless loop" \
  '[ "$(state "$lost_always" gate)" = escalation ]'

echo "failed result: a review that found blockers"
failed="$(new_task "Review that found blockers")"
set_at_review "$failed"
start_step "$failed"
step_result "$failed" review "$FAILED_REVIEW"
finish_step "$failed"
check "FailedReviewResult_GoesToImplement: blockers are work for implement, so the item leaves the review" \
  '[ "$(state "$failed" step)" = implement ]'

echo "background wait: the ceiling a Claude session gets"
mkdir -p "$fake_claude_folder"
printf '#!/bin/sh\nprintf "%%s\\n" "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-unset}"\n' > "$fake_claude_folder/claude"
chmod +x "$fake_claude_folder/claude"
check "ClaudeStepWithNoCeilingExported_GetsTheFlowsCeiling: the host's own ten minutes stopped reviewers mid-run, so a step gets the flow's longer wait" \
  '[ "$(ceiling_seen_by_claude -u CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS)" = "$DEFAULT_CEILING_IN_MILLISECONDS" ]'
check "ClaudeStepWithACeilingExported_KeepsTheOwnersCeiling: the owner's own setting wins over the flow's" \
  '[ "$(ceiling_seen_by_claude CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="$OWNER_CEILING_IN_MILLISECONDS")" = "$OWNER_CEILING_IN_MILLISECONDS" ]'

echo "lost-result: $fails failure(s)"
[ "$fails" -eq 0 ]
