---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/claim.json
pattern: '"item"\s*:\s*"local:task/1"'
flags: ""
match: contains
---
The ready item is picked and the pool worktree is claimed for it.
