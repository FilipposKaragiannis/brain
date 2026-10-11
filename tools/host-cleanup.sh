#!/bin/sh
# Remove dangling skill symlinks left by the old install-skills.sh on this machine.
# Only deletes symlinks whose target no longer exists. Prints what it removes.
set -u
for dir in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills"; do
  [ -d "$dir" ] || continue
  find "$dir" -maxdepth 1 -type l ! -exec test -e {} \; -print | while read -r link; do
    rm "$link" && echo "removed $link"
  done
done
echo "Install the plugins instead:"
echo "  claude plugin install craft@brain-plugins meta@brain-plugins standards@brain-plugins"
echo "  codex plugin add craft@brain-plugins && codex plugin add meta@brain-plugins && codex plugin add standards@brain-plugins"
