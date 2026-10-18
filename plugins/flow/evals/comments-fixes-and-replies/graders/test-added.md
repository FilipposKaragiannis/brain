---
type: regex
target:
  source: file
  path: .pool/wt-1/tests/run.sh
pattern: 'hello stranger'
flags: ""
match: contains
---
The test the comment asks for checks that greet with no name prints hello stranger.
