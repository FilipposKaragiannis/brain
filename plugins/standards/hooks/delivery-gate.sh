#!/bin/sh
# Stop and SubagentStop gate for a session that works a flow item. Contract with the flow plugin:
#   <worktree>/.flow/claim.json            {item, step, ...}        the steward's claim
#   <main worktree>/.flow/runs/<slug>.json {item, step, reports}    a step in flight (next.sh)
#   <reports>/<step>.json                  {status, summary, ...}   the step result the agent writes
#   <reports>/verify.json                  {status, checks, attempts} the verify report
# Blocks (decision: block) while a step is in flight and its result is missing, and at the pr
# step while the verify report is not pass (until attempts reach 3, which is an escalation and a
# human gate), and at the pr step whenever the report's head commit is not the PR head: the
# pushed copy of the worktree's own branch (read locally, no network call), or the worktree HEAD
# before one exists.
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
pr_head() {
  branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [ -n "$branch" ]; then
    remote="$(git config "branch.$branch.remote" 2>/dev/null)"
    git rev-parse --verify --quiet "refs/remotes/${remote:-origin}/$branch^{commit}" 2>/dev/null && return
  fi
  git rev-parse --verify --quiet 'HEAD^{commit}'
}
pr_step_reason() {
  report="$reports/verify.json"
  if [ ! -f "$report" ]; then
    printf '%s' "No verify report for $item at $report. The pr step needs a passing verify. Run verify first, or escalate with the error text."
    return
  fi
  content="$(cat "$report")"
  report_head="$(json_get "$content" "head")"
  current_head="$(pr_head)"
  if [ "$report_head" != "$current_head" ]; then
    printf '%s' "The verify report for $item was made at ${report_head:-no commit} but the PR head is ${current_head:-unknown}. Run verify again on the PR head, whatever the attempt count."
    return
  fi
  status="$(json_get "$content" "status")"
  attempts="$(json_get "$content" "attempts")"
  [ "$status" = "pass" ] && return
  [ "${attempts:-0}" -ge 3 ] 2>/dev/null && return
  failing="$(json_list "$content" "checks" | while read -r check; do
    [ "$(json_get "$check" "status")" = "pass" ] || printf '%s: %s. ' "$(json_get "$check" "name")" "$(json_get "$check" "summary")"
  done)"
  printf '%s' "The verify report for $item is $status (attempt ${attempts:-0} of 3). Failing checks: ${failing}No PR until verify passes; fix and verify again, or escalate after the third attempt."
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
