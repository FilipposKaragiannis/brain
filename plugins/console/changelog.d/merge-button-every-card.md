bump: minor

- Every pool card on Worktrees carries "Merge <base> in", whatever its state, so a branch far
  behind under a gate can still be brought up to date from the console. The button is disabled,
  with the daemon's reason on hover, while the worktree is unclaimed, unread by git, has
  uncommitted files, a run record or an agent; it is primary while the branch is far behind. The
  stale card says its way out in words. The health job's own sync notes are unchanged.
