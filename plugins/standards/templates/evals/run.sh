#!/bin/sh
# Run this project's agent evals: the cases in the folder `project.evals` names in
# .standards/config.json, against the agents rendered into .claude/agents/. Written by
# standards:init (templates/evals/run.sh in the plugin); init replaces it, so edit the plugin.
# Costs money (every run spawns the agent under test); not run in CI. Claude only: Codex has no
# plugin eval, and its agents render from the same briefs.
#   .standards/evals/run.sh [extra claude plugin eval flags, e.g. --case 'physics-*' --runs 1]
# claude plugin eval loads agents only from a plugin, so each run assembles a throwaway wrapper
# plugin: the manifest, copies of .claude/agents/*.md, and `cases` as a link to the real folder,
# so a case's scaffold script still finds this repo from its own path. The agents run as
# <repo folder>:<name>. Results land in .standards/evals/results/<time>/ (git-ignored).
# The exit status is the eval's.
set -u
cd "$(dirname "$0")/../.." || exit 2
cases="$(python3 -c 'import json; print((json.load(open(".standards/config.json")).get("project") or {}).get("evals") or "")' 2>/dev/null)"
if [ -z "$cases" ] || [ ! -d "$cases" ]; then
  echo "evals: no cases to run. Set project.evals in .standards/config.json to a folder of claude plugin eval cases (see AGENT-EVALS.md beside the standards plugin's init skill)."
  exit 0
fi
case "$cases" in /*) ;; *) cases="$PWD/$cases" ;; esac
name="$(basename "$PWD" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9-]/-/g')"
tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM
mkdir -p "$tmp/.claude-plugin" "$tmp/agents"
printf '{"name": "%s", "version": "0.0.0", "description": "Throwaway wrapper for .standards/evals/run.sh.", "experimental": {"evals": "cases"}}\n' "$name" > "$tmp/.claude-plugin/plugin.json"
for f in .claude/agents/*.md; do [ -f "$f" ] && cp "$f" "$tmp/agents/"; done
ln -s "$cases" "$tmp/cases"
status=0
claude plugin eval "$tmp" --scaffold --allow-tools Bash Read Glob Grep Agent --trust-plugin --no-publish \
  --ablation none --judge-model sonnet --output-dir ".standards/evals/results/$(date +%Y%m%d-%H%M%S)" "$@" || status=$?
exit "$status"
