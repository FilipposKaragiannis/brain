#!/bin/sh
# WorktreeCreate hook (Claude). Stdin: {name, cwd, ...}. Prints the path of a claimed pool
# worktree as the last stdout line. Claude allows only letters, digits, dots, underscores and
# dashes in a name, so the item id comes in slug form: gh-12 for gh#12, local-task-3 for
# local:task/3. Such a name claims for that item and records it in the tracker; any other name
# claims as adhoc:<name>. Fails (exit 1)
# when the project has no .flow/config.yaml or the pool is full, so Claude reports the error
# instead of creating a worktree outside the pool.
FLOW_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/flow.sh"
payload="$(cat 2>/dev/null || true)"
name="$(json_get "$payload" name)"
cwd="$(json_get "$payload" cwd)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
[ -f "$(config_file)" ] || die "no .flow/config.yaml in this repository; run flow:init or start without --worktree"
item="$(printf '%s' "$name" | sed -n 's/^gh-\([0-9][0-9]*\)$/gh#\1/p; s/^local-\([a-z][a-z0-9]*\)-\([0-9][0-9]*\)$/local:\1\/\2/p')"
[ -n "$item" ] || item="adhoc:${name:-session}"
path="$("$FLOW_PLUGIN/scripts/steward.sh" claim "$item")" || exit 1
printf '%s\n' "$path"
