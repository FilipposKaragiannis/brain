#!/bin/sh
# Stop and SubagentStop gate for a session that works a flow item. Contract with the flow plugin:
#   <worktree>/.flow/claim.json            {item, step, ...}        the steward's claim
#   <main worktree>/.flow/runs/<slug>.json {item, step, reports}    a step in flight (next.sh)
#   <reports>/<step>.json                  {status, summary, ...}   the step result the agent writes
#   <reports>/verify.json                  {status, checks, attempts} the verify report
# Blocks (decision: block) while a step is in flight and its result is missing, and at the pr
# step while the verify report is not pass (until attempts reach 3, which is an escalation and a
# human gate). Honours stop_hook_active so one block never becomes a loop. FLOW_HOME overrides
# the main worktree's .flow (tests).
. "$(dirname "$0")/lib.sh"
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
reason=""
if [ -n "$step" ] && [ ! -f "$reports/$step.json" ]; then
  reason="Step $step of $item is in flight and has no result. Write $reports/$step.json ({\"status\": \"done|fail|gate\", \"summary\": ...}) before stopping, or report the failure so the orchestrator can run advance.sh --status fail."
elif [ "$step" = "pr" ]; then
  report="$reports/verify.json"
  if [ ! -f "$report" ]; then
    reason="No verify report for $item at $report. The pr step needs a passing verify. Run verify first, or escalate with the error text."
  else
    content="$(cat "$report")"
    status="$(json_get "$content" "status")"
    attempts="$(json_get "$content" "attempts")"
    if [ "$status" != "pass" ] && ! [ "${attempts:-0}" -ge 3 ] 2>/dev/null; then
      failing="$(json_list "$content" "checks" | while read -r check; do
        [ "$(json_get "$check" "status")" = "pass" ] || printf '%s: %s. ' "$(json_get "$check" "name")" "$(json_get "$check" "summary")"
      done)"
      reason="The verify report for $item is $status (attempt ${attempts:-0} of 3). Failing checks: ${failing}No PR until verify passes; fix and verify again, or escalate after the third attempt."
    fi
  fi
fi
[ -n "$reason" ] || exit 0
printf '{"decision":"block","reason":%s}\n' "$(json_string "$reason")"
exit 0
