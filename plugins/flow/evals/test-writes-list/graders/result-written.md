---
type: regex
target:
  source: file
  path: .flow/reports/local-task-1/test.json
pattern: '"status":\s*"done"'
flags: ""
match: contains
---
The test step's result file says done.
