---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/review.json
pattern: '"status"\s*:\s*"fail"[\s\S]*(?:standards:review|engine)|(?:standards:review|engine)[\s\S]*"status"\s*:\s*"fail"'
flags: "i"
match: contains
---
An engine that could not run is a failed step, with the reason.
