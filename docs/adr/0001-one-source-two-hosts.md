# ADR 0001: one source, two hosts

Date: 2026-10-10. Status: accepted.

## Context
Every plugin shipped two hand-written manifests (Claude and Codex) and the skills reached the hosts
by symlink as well. Versions and descriptions drifted. Nothing checked them.

## Decision
- Each plugin has one source file, `plugins/<plugin>/plugin.source.json`. Every agent has one
  entry in `roster/agents.json` and one brief in `roster/briefs/<agent>.md`.
- `tools/generate.sh` renders both marketplace files, both plugin manifests, every
  `skills/*/agents/openai.yaml`, the Claude agents (`agents/*.md`) and the Codex agents
  (`codex-agents/*.toml`). Generated files are committed and never hand-edited.
- `tools/lint.sh` fails when a generated file is stale, a skill is malformed, or an agent exists
  outside the roster. CI runs it on every push.
- Sources are JSON, not YAML. The generator must run on a bare macOS `python3` (3.9, no PyYAML,
  no tomllib) and in CI with nothing installed.
- The Codex manifests stay generated even though Codex reads the Claude ones (phase 0 spike C).
  That fallback is undocumented.

## Consequences
- A version bump is one edit. A new agent is one roster entry and one brief.
- Legacy plugins without a source file (`workstream`, `spec-driven-development`) are listed as
  they are until the project side retires them.
