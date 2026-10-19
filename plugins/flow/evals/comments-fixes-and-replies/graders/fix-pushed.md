---
type: regex
target:
  source: file
  path: .origin.git/logs/refs/heads/flow/local-task-1
pattern: '(?:\tpush[^\n]*\n[\s\S]*){2}'
flags: ""
match: contains
---
The fix is pushed: the origin has a push after the fixture's.
