---
type: regex
target:
  source: file
  path: .main/.fake-gh/calls.log
pattern: '^pr create\b'
flags: "m"
match: contains
---
