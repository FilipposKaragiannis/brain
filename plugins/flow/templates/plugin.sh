# Written by flow:init. Sourced by the wrappers in .flow/: sets FLOW_PLUGIN to the installed flow
# plugin, found when the wrapper runs, so the repository holds no machine path and no version.
# FLOW_PLUGIN set by the caller wins; else the newest flow in the Claude plugin cache, else the
# newest in the Codex one. Exits 2 when neither has it.
if [ -z "${FLOW_PLUGIN:-}" ]; then
  for _flow_cache in "$HOME/.claude/plugins/cache" "$HOME/.codex/plugins/cache"; do
    FLOW_PLUGIN="$(for _flow_d in "$_flow_cache"/*/flow/*/; do
        [ -f "$_flow_d/scripts/next.sh" ] && printf '%s\t%s\n' "$(basename "$_flow_d")" "${_flow_d%/}"
      done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | cut -f2)"
    [ -n "$FLOW_PLUGIN" ] && break
  done
fi
[ -n "${FLOW_PLUGIN:-}" ] || { echo "flow: no installed flow plugin in ~/.claude or ~/.codex; install it, or set FLOW_PLUGIN" >&2; exit 2; }
export FLOW_PLUGIN
