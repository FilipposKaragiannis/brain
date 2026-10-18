---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"isResolved": true'
flags: ""
match: contains
---
The thread is resolved after the reply.
