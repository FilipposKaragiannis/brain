---
type: regex
target:
  source: file
  path: .main/.git/logs/refs/heads/flow/local-task-1
pattern: '\tcommit: (?!feat\(greet\): greet strangers when no name is given)'
flags: ""
match: contains
---
The test writer committed the tests on the task branch, after the fixture's fix commit.
