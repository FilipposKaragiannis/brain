---
type: regex
target:
  source: file
  path: .fake-gh/calls.log
pattern: '^pr create\b'
flags: "m"
match: not_contains
---
A failing verify never gets a PR.
