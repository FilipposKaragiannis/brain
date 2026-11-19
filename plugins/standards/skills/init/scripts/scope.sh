#!/bin/sh
stamp_names_a_host_folder() {
  awk -F'\t' 'NR > 1 && substr($2, 1, 1) == "/" { host_folder_found = 1 } END { exit !host_folder_found }' "$1"
}
project_scope_leftovers() {
  for instructions_file in AGENTS.md CLAUDE.md; do
    [ -f "$instructions_file" ] && grep -q '<!-- standards:begin' "$instructions_file" && printf '%s ' "$instructions_file"
  done
  for project_rule in .claude/rules/standards-*.md; do [ -f "$project_rule" ] && printf '%s ' '.claude/rules/standards-*.md' && break; done
  for plugin_agent in "$plugin"/codex-agents/*.toml; do
    [ -f ".codex/agents/${plugin_agent##*/}" ] && printf '%s ' ".codex/agents/${plugin_agent##*/}"
  done
}
install_scope_blocks() {
  if [ "$scope" = machine ]; then
    [ "$check" -eq 1 ] || mkdir -p "$claude_home" "$codex_home"
    install_block "$claude_home/CLAUDE.md"
    install_block "$codex_home/AGENTS.md"
    return
  fi
  if [ -e AGENTS.md ]; then install_block AGENTS.md; elif [ -e CLAUDE.md ]; then install_block CLAUDE.md; else install_block AGENTS.md; fi
  if [ -e CLAUDE.md ] && [ -e AGENTS.md ] && [ "$(realpath_py CLAUDE.md)" != "$(realpath_py AGENTS.md)" ]; then install_block CLAUDE.md; fi
}
print_scope_next_steps() {
  if [ "$scope" = machine ]; then
    echo "  - the standards block, the Claude rules and the Codex agents live in $claude_home and $codex_home and apply to every project on this machine"
    return
  fi
  echo "  - commit the changes with [config] in the message: .standards/ and .githooks/ are protected files"
  hooks_path_outcome="init did not set it here; see above"
  [ "$(git config core.hooksPath 2>/dev/null)" = "$wanted_hooks_path" ] && hooks_path_outcome="init does it here"
  echo "  - every clone sets the git hooks path once: git config core.hooksPath $wanted_hooks_path ($hooks_path_outcome)"
}
scope_copy() {
  if [ "$scope" = machine ]; then printf '%s' "$2"; return; fi
  project_copy "$1" "$2"
}

main_worktree_folder="$(main_worktree)"
[ -n "$main_worktree_folder" ] || main_worktree_folder="$PWD"
main_stamp="$main_worktree_folder/.standards/stamp"
if [ -n "$scope" ]; then scope_reason="--scope $scope"
elif [ ! -f "$main_stamp" ]; then scope=project; scope_reason="the default; --scope machine leaves the project's files as they are"
elif stamp_names_a_host_folder "$main_stamp"; then scope=machine; scope_reason="the last init chose it"
else scope=project; scope_reason="the last init chose it"; fi
echo "init: scope: $scope ($scope_reason)"

claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
rules_folder=".claude/rules"; codex_agents_folder=".codex/agents"
if [ "$scope" = machine ]; then
  case "$claude_home" in /*) ;; *) echo "init: CLAUDE_CONFIG_DIR must be an absolute path, not $claude_home" >&2; exit 2 ;; esac
  case "$codex_home" in /*) ;; *) echo "init: CODEX_HOME must be an absolute path, not $codex_home" >&2; exit 2 ;; esac
  cd "$main_worktree_folder" || exit 2
  rules_folder="$claude_home/rules"; codex_agents_folder="$codex_home/agents"
  [ -s "$codex_home/AGENTS.override.md" ] && echo "init: note: $codex_home/AGENTS.override.md is not empty, so Codex reads it instead of $codex_home/AGENTS.md and does not see the standards block"
  leftovers="$(project_scope_leftovers)"
  [ -n "$leftovers" ] && echo "init: note: an earlier project-scope install left ${leftovers% } in the project; machine scope leaves them as they are. Removing them is a change to the project's files, so do it yourself when you want them gone."
fi
