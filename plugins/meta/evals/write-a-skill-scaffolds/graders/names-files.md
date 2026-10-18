---
type: regex
pattern: "^(?=[\\s\\S]*SKILL\\.md)(?=[\\s\\S]*(?:case\\.yaml|evals/))(?=[\\s\\S]*plugin\\.source\\.json)"
flags: ""
match: contains
target: last_message
---
The final message names the files written: SKILL.md, the eval case and the plugin.source.json entry.
