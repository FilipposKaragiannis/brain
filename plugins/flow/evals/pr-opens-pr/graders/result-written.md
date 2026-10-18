---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/pr.json
pattern: '"status"\s*:\s*"done"[\s\S]*https://gh/pull/91|https://gh/pull/91[\s\S]*"status"\s*:\s*"done"'
flags: ""
match: contains
---
