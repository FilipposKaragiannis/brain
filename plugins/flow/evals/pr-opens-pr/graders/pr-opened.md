---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{(?=[^{}]*"url": "https://gh/pull/91")(?=[^{}]*"baseRefName": "main")(?=[^{}]*"headRefName": "flow/local-task-1")'
flags: ""
match: contains
---
The PR is open from the task branch against main, the config's base: the item has no parent.
