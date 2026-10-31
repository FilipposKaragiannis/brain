#!/bin/sh
# Unattended flow run. Installed by flow:init as <repo>/.flow/run-unattended.sh.
#   .flow/run-unattended.sh <claude|codex> [item] [--max-steps N]
# A shell loop is the orchestrator: next.sh prepares a step, the host runs its brief with the
# claimed worktree as the working directory, advance.sh applies the result; repeat until a gate,
# nothing ready, or done. Each step is a fresh host process with the step agent's model and
# effort from the roster; a step with no agent (design, implement, review, explain) gets the
# jobs' pair for the host, jobs.<host>.model and jobs.<host>.effort, so no step runs on the host's
# bare default unless that pair is empty (lib/host.sh holds the host command lines). Each step
# session is a line in <flow home>/log/runs.jsonl with its model, effort and usage. A session that
# fails on a spend limit or an auth error raises the escalation gate on its item, naming the
# cause, and stops the host: this loop and every other one start no session on it until the
# owner clears the gate (exit 4, as for any gate).
set -u
host="${1:-}"; shift || true
[ "$host" = "claude" ] || [ "$host" = "codex" ] || { echo "usage: run-unattended.sh <claude|codex> [item] [--max-steps N]" >&2; exit 2; }
FLOW_RUN_PID=$$; export FLOW_RUN_PID   # next.sh records it, so the health job knows this loop is alive
FLOW_HOST_GATES=1                      # a host stop raises the item's gate here, which tells the owner
item=""; max=20
while [ $# -gt 0 ]; do case "$1" in --max-steps) max="$2"; shift 2 ;; *) item="$1"; shift ;; esac; done
. "$(dirname "$0")/plugin.sh"
plugin="$FLOW_PLUGIN"
. "$plugin/lib/host.sh"
host_check "$host" || exit 2
# The jobs' pair is checked before a step is claimed: an effort the host does not take would fail
# the agent-less step's session after next.sh recorded its run.
bad="$(host_jobs_pair_problem "$host")"
[ -z "$bad" ] || { echo "run-unattended: $bad" >&2; exit 2; }
host_jobs_pair "$host"
n=0
while [ "$n" -lt "$max" ]; do
  n=$((n + 1))
  stopped="$(host_stopped "$host")"
  [ -z "$stopped" ] || { echo "run-unattended: $stopped"; exit 4; }
  step="$("$plugin/scripts/next.sh" --json --embed-agent $item)"; code=$?
  [ "$code" -eq 0 ] || { echo "run-unattended: next.sh exit $code"; exit "$code"; }
  get() { printf '%s' "$step" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }
  item="$(get item)"; wt="$(get worktree)"; brief="$(get brief)"; model="$(get model)"; effort="$(get effort)"; agent="$(get agent)"
  names=roster
  [ -n "$agent" ] || { model="$jobs_model"; effort="$jobs_effort"; names=as-is; }
  echo "run-unattended: $item step $(get step) in $wt"
  prompt="Follow the brief in $brief exactly. Work in $wt."
  skill="$(get skill)"; [ -n "$skill" ] && [ -z "$agent" ] && prompt="$(host_skill_prompt "$host" flow "$skill" "$item. $prompt")"
  t0="$(date +%s)"
  host_run "$host" "$wt" "$prompt" "$model" "$effort" "$names"; hcode=$?
  shown="$model"; [ "$names" = as-is ] || [ "$host" != codex ] || shown="$(host_codex_model "$model")"
  # Another loop stopped the host between this pick and its session: nothing ran, so the run
  # record goes and the item waits at its step, as for a gate.
  if [ "$hcode" -eq 75 ] && [ -n "$(host_stopped "$host")" ]; then
    rm -f "$(flow_home)/runs/$(item_slug "$item").json"
    echo "run-unattended: $(host_stopped "$host")"; exit 4
  fi
  host_record "$item" "$(get step)" "$shown" "$effort" "$t0" "$hcode"
  if [ -n "$host_cause" ]; then
    host_stop_item "$host" "$item"
    on="$(json_get "$(cat "$(host_stop_file "$host")")" item)"
    "$plugin/scripts/gate.sh" raise "$item" escalation "The $(get step) step stopped: $host failed on $(host_cause_said "$host_cause"): $host_said
No $host session starts, on any item, until the gate on $on clears. $(host_stop_fix "$host" "$host_cause"), then clear the gate." >/dev/null
    echo "run-unattended: $item stopped at an escalation gate: $host failed on $(host_cause_said "$host_cause")"
    exit 4
  fi
  "$plugin/scripts/advance.sh" "$item"; code=$?
  [ "$code" -eq 0 ] || { echo "run-unattended: stopped (exit $code)"; exit "$code"; }
done
echo "run-unattended: step budget $max reached"
