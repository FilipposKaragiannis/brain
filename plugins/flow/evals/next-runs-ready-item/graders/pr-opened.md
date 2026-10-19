---
type: regex
target:
  source: file
  path: .fake-gh/calls.log
pattern: '^pr create\b'
flags: "m"
match: contains
---
