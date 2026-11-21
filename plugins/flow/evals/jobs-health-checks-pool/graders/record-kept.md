---
type: regex
target:
  source: file
  path: .flow/state/local-task-1.json
pattern: '"run"\s*:\s*\{'
flags: ""
match: contains
---
The dead run's record is still there.
