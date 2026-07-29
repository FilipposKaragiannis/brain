#!/bin/sh
# PostToolUse hook (Bash matcher): after a `git commit` that touches a SKILL.md
# under AI/skills or plugins/*/skills, remind the agent to republish the live
# arsenal artifact via the Artifact tool. A plain git hook can't do this step
# itself — only the agent can call the Artifact tool.

cmd="$(jq -r '.tool_input.command // empty')"
echo "$cmd" | grep -qE '(^|[;&|]|[[:space:]])git[[:space:]]+commit([[:space:]]|$)' || exit 0

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" || exit 0

CHANGED="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null)"
echo "$CHANGED" | grep -qE '^(AI/skills|plugins/[^/]+/skills)/.*SKILL\.md$' || exit 0

jq -n '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:"This commit touched a SKILL.md file. The git post-commit hook already regenerated .scratch/skills-arsenal.html — now use the Artifact tool to republish it to the live arsenal artifact URL (see AI/skills/arsenal/SKILL.md for the URL and process) before finishing this turn."}}'
