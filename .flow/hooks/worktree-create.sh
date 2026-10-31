#!/bin/sh
# Written by flow:init. Claude WorktreeCreate hook: lands --worktree sessions in the pool.
. "$(dirname "$0")/../plugin.sh"
exec "$FLOW_PLUGIN/hooks/worktree-create.sh" "$@"
