#!/bin/sh
# WorktreeCreate hook (Claude). Stdin: {name, cwd, ...}. Prints the path of a claimed pool
# worktree as the last stdout line. Claude allows only letters, digits, dots, underscores and
# dashes in a name, so the item id comes in slug form: gh-12 for gh#12, local-task-3 for
# local:task/3. Such a name claims for that item from the base lib/base.sh claim_at_base resolves,
# as next.sh does, and records it in the tracker; any other name claims as adhoc:<name> from the
# config base. Fails (exit 1) when the project has no .flow/config.yaml, the item cannot be read,
# its base: line names a branch not on the remote or the pool is full, so Claude reports the error
# instead of creating a worktree outside the pool or on the wrong history.
FLOW_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
payload="$(cat 2>/dev/null || true)"
name="$(json_get "$payload" name)"
cwd="$(json_get "$payload" cwd)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
[ -f "$(config_file)" ] || die "no .flow/config.yaml in this repository; run flow:init or start without --worktree"
item="$(slug_item "$name")"
if [ -n "$item" ]; then
  item_json="$(adapter read "$item" </dev/null)" || die "cannot read $item"
  path="$(claim_at_base "$item" "$item_json")" || exit 1
else
  path="$("$FLOW_PLUGIN/scripts/steward.sh" claim "adhoc:${name:-session}")" || exit 1
fi
printf '%s\n' "$path"
