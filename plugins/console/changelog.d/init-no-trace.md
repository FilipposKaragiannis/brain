bump: patch

- Tests prove that adding a project and watching it work when its `.flow/` is excluded in
  `.git/info/exclude` and untracked, as `flow:init` now leaves it: the console reads the flow home
  and the claims from the disk, and the worktrees count no dirty files for them. No code changed.
