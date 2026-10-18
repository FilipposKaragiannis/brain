---
type: regex
pattern: "^(?=[\\s\\S]*\\.pool/wt-1)(?=[\\s\\S]*(?:flow/local-task-1|task branch))"
flags: ""
match: contains
target: last_message
---
The final message says where the commit landed: the task branch in the pool worktree (.pool/wt-1).
