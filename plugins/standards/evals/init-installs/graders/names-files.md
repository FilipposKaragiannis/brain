---
type: regex
pattern: "^(?=[\\s\\S]*AGENTS\\.md)(?=[\\s\\S]*config\\.json)(?=[\\s\\S]*(?:\\.standards/rules|[\\s`(]rules/))(?=[\\s\\S]*\\.claude/rules)(?=[\\s\\S]*\\.codex/agents)(?=[\\s\\S]*hooks)"
flags: ""
match: contains
target: last_message
---
The report names the files that changed: the block in AGENTS.md, .standards/config.json, the
rule text under .standards/rules (grouped by folder is fine), .claude/rules, .codex/agents and
the git hooks.
