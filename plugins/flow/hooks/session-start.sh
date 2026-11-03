#!/bin/sh
# SessionStart hook: a few milliseconds to lift the pool worktrees' pinned plugin versions to the
# newest installed (scripts/_plugins.py), then to say whether the project's installed flow files
# are behind this plugin. Compares the install set's hash with the first line of .flow/stamp
# (written by init). Silent when the project does not use the flow, when the stamp matches, and
# when the copies still match it. Never looks at hand edits (that is `init --check`). Prints on
# stdout, which the host adds to the session's context.
FLOW_PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"; export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/flow.sh"
cat >/dev/null 2>&1 || true
root="$(repo_root)" || exit 0
# The flow home is the main worktree's .flow: it is not committed, so a linked worktree has none.
home="$(cd "$root" && flow_home)"
[ -f "$home/config.yaml" ] || exit 0
python3 -I "$FLOW_PLUGIN/scripts/_plugins.py" sync "$root" 2>/dev/null || true
init="$FLOW_PLUGIN/skills/init/scripts/init.sh"
stamp="$home/stamp"
if [ ! -f "$stamp" ]; then
  echo "flow: note for the owner, not a task: this project has no install stamp (installed before flow 0.2.0). /flow:init writes .flow/stamp on its next run."
  exit 0
fi
# init writes the hooks to the main worktree's local settings, beside the flow home.
main="$(dirname "$home")"
if [ -d "$main/.claude" ] && ! claude_hooks_present "$main"; then
  echo "flow: note for the owner, not a task: .claude/settings.local.json has no flow worktree hooks, so claude --worktree lands outside the pool. /flow:init writes them."
fi
[ "$(stamp_source "$stamp")" = "$(flow_source_hash "$FLOW_PLUGIN")" ] && exit 0
version="$(json_get "$(cat "$FLOW_PLUGIN/.claude-plugin/plugin.json")" "version")"
report="$("$init" --root "$root" --check 2>&1)"
# The copies still match: nothing to do, so nothing to say. The next init refreshes the stamp.
if printf '%s' "$report" | grep -q 'up to date'; then :
else
  echo "flow: the installed copies are behind flow v$version. Run /flow:init (Codex: \$init) to refresh them. Drift:"
  printf '%s\n' "$report" | sed 's/^/  /'
fi
exit 0
