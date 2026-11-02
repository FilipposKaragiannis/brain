bump: patch

- A claim (or reserve) that would grow the pool with a refused `worktree_name` (no `{n}`, or one
  that gives every number the same idle branch) exits 2 with the template's reason and no pool_max
  message; a full pool still exits 3. Tests now pin both, and the steward.sh header names the
  `worktree_name` template that names a grown worktree.
