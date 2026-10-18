---
type: regex
pattern: "^(?=[\\s\\S]*^[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*pool_max)(?=[\\s\\S]*^[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*worktree_copy)(?=[\\s\\S]*^[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*worktree_setup)(?=[\\s\\S]*^[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*\\bgates\\b)"
flags: "m"
match: contains
target: last_message
---
The report ends with the config questions as numbered items, at least pool_max, worktree_copy,
worktree_setup and gates, in the same message as the files (the report is not held back for the
answers).
