#!/bin/sh
# Stop and SubagentStop gate for a session that works a flow item. Contract with the flow plugin:
#   <worktree>/.flow/claim.json            {item, step, ...}        the steward's claim
#   <main worktree>/.flow/runs/<slug>.json {item, step, reports}    a step in flight (next.sh)
#   <reports>/<step>.json                  {status, summary, ...}   the step result the agent writes
#   <reports>/verify.json                  {status, checks, attempts} the verify report
# Blocks (decision: block) while a step is in flight and its result is missing, and at the pr
# step while the verify report is not pass (until attempts reach 3, which is an escalation and a
# human gate), and at the pr step whenever the report's head commit is not the PR head (the report
# holds the short id, so it matches by prefix): the pushed copy of the worktree's own branch (read
# locally, no network call), or the worktree HEAD before one exists.
# Honours stop_hook_active so one block never becomes a loop. FLOW_HOME overrides the main
# worktree's .flow (tests).
. "$(dirname "$0")/lib.sh"
use_working_git
payload="$(read_payload)"
[ "$(json_get "$payload" "stop_hook_active")" = "true" ] && exit 0
root="$(repo_root)" || exit 0
[ -f "$root/.flow/claim.json" ] || exit 0
item="$(json_get "$(cat "$root/.flow/claim.json")" "item")"
[ -n "$item" ] || exit 0
slug="$(printf '%s' "$item" | tr ':/#' '---')"
home="${FLOW_HOME:-$(main_worktree)/.flow}"
run_file="$home/runs/$slug.json"
[ -f "$run_file" ] || exit 0
run="$(cat "$run_file")"
step="$(json_get "$run" "step")"
reports="$(json_get "$run" "reports")"
[ -n "$reports" ] || reports="$root/.flow/reports/$slug"
verify_attempt_limit=3
pr_head() {
  pr_head_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [ -n "$pr_head_branch" ]; then
    pr_head_remote="$(git config "branch.$pr_head_branch.remote" 2>/dev/null)"
    git rev-parse --verify --quiet "refs/remotes/${pr_head_remote:-origin}/$pr_head_branch^{commit}" 2>/dev/null && return
  fi
  git rev-parse --verify --quiet 'HEAD^{commit}'
}
stale_report_reason() {
  stale_report_head="$(json_get "$1" "head")"
  stale_current_head="$(pr_head)"
  [ -n "$stale_report_head" ] && case "$stale_current_head" in "$stale_report_head"*) return ;; esac
  printf '%s' "The verify report for $item was made at ${stale_report_head:-no commit} but the PR head is ${stale_current_head:-unknown}. Run verify again on the PR head, whatever the attempt count."
}
failing_report_reason() {
  failing_status="$(json_get "$1" "status")"
  failing_attempts="$(json_get "$1" "attempts")"
  [ "$failing_status" = "pass" ] && return
  [ "${failing_attempts:-0}" -ge "$verify_attempt_limit" ] 2>/dev/null && return
  failing_checks="$(json_list "$1" "checks" | while read -r failing_check; do
    [ "$(json_get "$failing_check" "status")" = "pass" ] || printf '%s: %s. ' "$(json_get "$failing_check" "name")" "$(json_get "$failing_check" "summary")"
  done)"
  printf '%s' "The verify report for $item is $failing_status (attempt ${failing_attempts:-0} of $verify_attempt_limit). Failing checks: ${failing_checks}No PR until verify passes; fix and verify again, or escalate after the third attempt."
}
pr_step_reason() {
  pr_step_report="$reports/verify.json"
  if [ ! -f "$pr_step_report" ]; then
    printf '%s' "No verify report for $item at $pr_step_report. The pr step needs a passing verify. Run verify first, or escalate with the error text."
    return
  fi
  pr_step_content="$(cat "$pr_step_report")"
  pr_step_stale="$(stale_report_reason "$pr_step_content")"
  if [ -n "$pr_step_stale" ]; then
    printf '%s' "$pr_step_stale"
    return
  fi
  failing_report_reason "$pr_step_content"
}
reason=""
if [ -n "$step" ] && [ ! -f "$reports/$step.json" ]; then
  reason="Step $step of $item is in flight and has no result. Write $reports/$step.json ({\"status\": \"done|fail|gate\", \"summary\": ...}) before stopping, or report the failure so the orchestrator can run advance.sh --status fail."
elif [ "$step" = "pr" ]; then
  reason="$(pr_step_reason)"
fi
[ -n "$reason" ] || exit 0
printf '{"decision":"block","reason":%s}\n' "$(json_string "$reason")"
exit 0
