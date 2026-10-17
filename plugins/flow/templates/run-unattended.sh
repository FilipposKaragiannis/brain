#!/bin/sh
# Unattended flow run. Installed by flow:init as <repo>/.flow/run-unattended.sh.
#   .flow/run-unattended.sh <claude|codex> [item] [--max-steps N]
# A shell loop is the orchestrator: next.sh prepares a step, the host runs its brief with the
# claimed worktree as the working directory, advance.sh applies the result; repeat until a gate,
# nothing ready, or done. Each step is a fresh host process with the step agent's model and
# effort from the roster (lib/host.sh holds the host command lines).
set -u
host="${1:-}"; shift || true
[ "$host" = "claude" ] || [ "$host" = "codex" ] || { echo "usage: run-unattended.sh <claude|codex> [item] [--max-steps N]" >&2; exit 2; }
item=""; max=20
while [ $# -gt 0 ]; do case "$1" in --max-steps) max="$2"; shift 2 ;; *) item="$1"; shift ;; esac; done
. "$(dirname "$0")/plugin.sh"
plugin="$FLOW_PLUGIN"
. "$plugin/lib/host.sh"
host_check "$host" || exit 2
n=0
while [ "$n" -lt "$max" ]; do
  n=$((n + 1))
  step="$("$plugin/scripts/next.sh" --json --embed-agent $item)"; code=$?
  [ "$code" -eq 0 ] || { echo "run-unattended: next.sh exit $code"; exit "$code"; }
  get() { printf '%s' "$step" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }
  item="$(get item)"; wt="$(get worktree)"; brief="$(get brief)"; model="$(get model)"; effort="$(get effort)"
  echo "run-unattended: $item step $(get step) in $wt"
  host_run "$host" "$wt" "Follow the brief in $brief exactly. Work in $wt." "$model" "$effort"
  "$plugin/scripts/advance.sh" "$item"; code=$?
  [ "$code" -eq 0 ] || { echo "run-unattended: stopped (exit $code)"; exit "$code"; }
done
echo "run-unattended: step budget $max reached"
