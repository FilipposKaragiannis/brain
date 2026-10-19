---
type: regex
target:
  source: file
  path: .git/logs/refs/heads/flow/local-task-1
pattern: 'commit: (?!feat\(greet\): greet strangers when no name is given)'
flags: ""
match: contains
---
A commit on the task branch after the fixture's own: the fix for the thread.
