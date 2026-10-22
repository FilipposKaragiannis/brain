---
type: regex
target:
  source: file
  path: .flow/runs/local-task-1.json
pattern: '"item"\s*:\s*"local:task/1"'
flags: ""
match: contains
---
The dead run's record is still there.
