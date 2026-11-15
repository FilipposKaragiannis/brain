#!/bin/sh
# SessionStart hook: a few milliseconds to say whether the project's installed copies of the
# standards are behind this plugin. Compares the install set's hash with the first line of
# .standards/stamp (written by init). Silent when the project does not use the plugin, when the
# stamp matches, and never looks at hand edits (that is `init --check`). Prints on stdout, which
# the host adds to the session's context.
. "$(dirname "$0")/lib.sh"
read_payload >/dev/null
root="$(repo_root)" || exit 0
[ -f "$root/.standards/config.json" ] || exit 0
plugin="$(cd "$(dirname "$0")/.." && pwd)"
init="$plugin/skills/init/scripts/init.sh"
stamp="$root/.standards/stamp"
if [ ! -f "$stamp" ]; then
  echo "standards: note for the owner, not a task: this project has no install stamp (installed before standards 0.2.0). /standards:init writes .standards/stamp on its next run."
  exit 0
fi
[ "$(stamp_source "$stamp")" = "$(standards_source_hash "$plugin")" ] && exit 0
version="$(json_get "$(cat "$plugin/.claude-plugin/plugin.json")" "version")"
report="$("$init" --root "$root" --check 2>&1)"
if printf '%s' "$report" | grep -q 'up to date'; then
  echo "standards: the plugin changed but the installed copies still match (v$version). Run /standards:init (Codex: \$init) once to refresh the stamp."
else
  echo "standards: the installed copies are behind standards v$version. Run /standards:init (Codex: \$init) to refresh them. Drift:"
  printf '%s\n' "$report" | sed 's/^/  /'
fi
exit 0
