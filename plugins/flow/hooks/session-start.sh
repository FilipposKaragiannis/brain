#!/bin/sh
# SessionStart hook: a few milliseconds to say whether the project's installed flow files are
# behind this plugin. Compares the install set's hash with the first line of .flow/stamp (written
# by init). Silent when the project does not use the flow, when the stamp matches, and never
# looks at hand edits (that is `init --check`). Prints on stdout, which the host adds to the
# session's context.
FLOW_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/flow.sh"
cat >/dev/null 2>&1 || true
root="$(repo_root)" || exit 0
[ -f "$root/.flow/config.yaml" ] || exit 0
init="$FLOW_PLUGIN/skills/init/scripts/init.sh"
stamp="$root/.flow/stamp"
if [ ! -f "$stamp" ]; then
  echo "flow: note for the owner, not a task: this project has no install stamp (installed before flow 0.2.0). /flow:init writes .flow/stamp on its next run."
  exit 0
fi
if [ -d "$root/.claude" ] && ! claude_hooks_present "$root"; then
  echo "flow: note for the owner, not a task: .claude/settings.json has no flow worktree hooks on this branch, so claude --worktree lands outside the pool. /flow:init prints the entry to add."
fi
[ "$(stamp_source "$stamp")" = "$(flow_source_hash "$FLOW_PLUGIN")" ] && exit 0
version="$(json_get "$(cat "$FLOW_PLUGIN/.claude-plugin/plugin.json")" "version")"
report="$("$init" --root "$root" --check 2>&1)"
if printf '%s' "$report" | grep -q 'up to date'; then
  echo "flow: the plugin changed but the installed copies still match (v$version). Run /flow:init (Codex: \$init) once to refresh the stamp."
else
  echo "flow: the installed copies are behind flow v$version. Run /flow:init (Codex: \$init) to refresh them. Drift:"
  printf '%s\n' "$report" | sed 's/^/  /'
fi
exit 0
