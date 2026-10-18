---
type: regex
target:
  source: file
  path: .flow/config.yaml
pattern: "^pool:[ \\t]*\\n(?:[ \\t]*#[^\\n]*\\n)*[ \\t]+- \\.\\./fixture-wt-1[ \\t]*$"
flags: "m"
match: contains
---
The installer fills the pool from the worktrees that already exist: .flow/config.yaml lists
../fixture-wt-1 under pool.
