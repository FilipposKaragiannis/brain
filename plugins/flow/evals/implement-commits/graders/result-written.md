---
type: regex
target:
  source: file
  path: .flow/reports/local-task-1/implement.json
pattern: '"status":\s*"done"'
flags: ""
match: contains
---
The implement step's result file says done.
