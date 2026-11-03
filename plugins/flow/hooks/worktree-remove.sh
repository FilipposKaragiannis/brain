#!/bin/sh
# WorktreeRemove hook (Claude). Stdin: {worktree_path, cwd, ...}. Releases the pool worktree:
# back to its idle branch at the base tip, task branch deleted when merged, claim cleared. The
# folder stays: it is the pool's. Claude Code reads exit 0 as removed and then leaves the folder
# alone, with no git fallback (2.1.317). Exits 3 and keeps everything when the worktree has
# uncommitted changes (the steward never resets those); Claude Code keeps a folder a hook leaves
# with a non-zero exit. A host that removes the folder anyway (a session with no WorktreeRemove
# entry falls back to git worktree remove) leaves a pool path missing on disk, which the next
# claim recreates.
FLOW_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/flow.sh"
payload="$(cat 2>/dev/null || true)"
path="$(json_get "$payload" worktree_path)"
cwd="$(json_get "$payload" cwd)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
[ -n "$path" ] || exit 0
[ -f "$path/.flow/claim.json" ] || exit 0
"$FLOW_PLUGIN/scripts/steward.sh" release "$path" >&2
