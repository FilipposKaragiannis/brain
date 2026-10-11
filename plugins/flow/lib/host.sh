#!/bin/sh
# One way to run a host CLI unattended, shared by the unattended loop and the jobs.
#   host_run <claude|codex> <dir> <prompt> [model] [effort]
# Claude: -p with dontAsk, so a tool outside the allow list is denied, not asked. Codex: exec
# with workspace-write and the plugin hooks trusted for this invocation; the project rules
# file lets git and gh run outside the sandbox. The model names are the roster's (Claude
# names); host_codex_model maps them for Codex. Stdin is closed so a prompt never waits.
host_check() {
  case "${1:-}" in claude|codex) command -v "$1" >/dev/null 2>&1 || { echo "flow: $1 is not installed" >&2; return 1; } ;;
    *) echo "flow: host must be claude or codex" >&2; return 2 ;; esac
}
host_codex_model() { printf '%s' "$1" | sed 's/^sonnet$/gpt-6-luna/; s/^opus$/gpt-6-sol/; s/^fable$/gpt-6-astra/; s/^haiku$/gpt-6-luna/'; }
host_run() {
  host="$1"; dir="$2"; prompt="$3"; model="${4:-}"; effort="${5:-}"
  case "$host" in
    claude)
      (cd "$dir" && claude -p "$prompt" --permission-mode dontAsk ${model:+--model "$model"} ${effort:+--effort "$effort"} < /dev/null) ;;
    codex)
      cmodel="$(host_codex_model "$model")"
      codex exec -C "$dir" -s workspace-write --dangerously-bypass-hook-trust -c 'approval_policy="never"' \
        ${cmodel:+-m "$cmodel"} ${effort:+-c "model_reasoning_effort=\"$effort\""} "$prompt" < /dev/null ;;
    *) echo "flow: host must be claude or codex" >&2; return 2 ;;
  esac
}
