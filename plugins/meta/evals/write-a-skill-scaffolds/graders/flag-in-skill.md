---
type: regex
target:
  source: file
  path: plugins/demo/skills/release-notes/SKILL.md
pattern: "^disable-model-invocation:[ \\t]*true[ \\t]*$"
flags: "m"
match: contains
---
The skill is user-invoked: its SKILL.md frontmatter has disable-model-invocation: true.
