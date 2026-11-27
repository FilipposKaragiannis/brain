---
type: regex
target:
  source: file
  path: .fake-gh/calls.log
pattern: '^pr create\b.* --attach \S*/evidence/screen\.png'
flags: "m"
match: contains
---
The PR is created with the verify capture's screenshot attached, so gh uploads it.
