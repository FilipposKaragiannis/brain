---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/claim.json
pattern: '"item"\s*:\s*"local:task/1"'
flags: ""
match: contains
---
The worktree is still claimed for the item.
