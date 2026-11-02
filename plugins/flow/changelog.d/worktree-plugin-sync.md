bump: minor

- The pool worktrees' plugin versions follow the newest installed one. Claude pins a plugin per
  project directory, and a linked worktree is its own directory, so it kept the version it first
  saw: `claude plugin update` run inside it reads the main checkout's record, and the marketplace
  auto-update never touches it. The `SessionStart` hook now runs `scripts/_plugins.py sync`, which
  lifts every worktree's record of the repository to the newest version any scope has in the
  plugin cache and says which it lifted; a session sees the new version at its next start.
