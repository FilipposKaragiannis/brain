#!/bin/sh
# WorktreeRemove hook (Claude). Stdin: {worktree_path, cwd, ...}. Releases the pool worktree:
# back to the base, task branch deleted when merged, claim cleared. Exits 3 and keeps everything
# when the worktree has uncommitted changes (the steward never resets those).
FLOW_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/flow.sh"
payload="$(cat 2>/dev/null || true)"
path="$(json_get "$payload" worktree_path)"
cwd="$(json_get "$payload" cwd)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
[ -n "$path" ] || exit 0
[ -f "$path/.flow/claim.json" ] || exit 0
"$FLOW_PLUGIN/scripts/steward.sh" release "$path" >&2
