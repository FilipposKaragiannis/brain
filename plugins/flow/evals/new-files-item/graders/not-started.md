---
type: regex
target:
  source: file
  path: .flow/items/task/2.md
pattern: '^(?=[\s\S]*^step: ""$)(?=[\s\S]*^worktree: ""$)'
flags: "m"
match: contains
---
Filing changes nothing else: no step started, no worktree claimed.
