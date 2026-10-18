---
type: regex
pattern: "the pool and pool_max, worktree_copy and worktree_setup, the base branch, the adapters|unverified on this version; unattended runs use -C|^\\s*Next:\\s*$"
flags: "m"
match: not_contains
target: last_message
---
The report does not paste the installer's output (its "Next:" header and lines quoted from it).
