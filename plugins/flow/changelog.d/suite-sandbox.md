bump: patch

- The flow suite can no longer change the checkout it runs from. Run with `GIT_DIR` exported, as
  from a git hook or an agent's session, its very first steps wrote its test identity into that
  repository's config, made commits on its `main` and added worktrees to it, and every later git
  call followed. Every flow suite now runs in the repository's test sandbox
  (`tools/lib/sandbox.sh`): it clears the git variables that point git at a repository and the
  ones that point git, Claude, Codex or flow at the owner's config, keeps git from looking above
  the suite's temp folder, and watches the checkout the suite runs from. A run that changes that
  repository's `core.bare`, `core.worktree` or `user.*`, adds a worktree into the temp folder or
  edits the plugin's files fails, and the lint fails on a suite that does not run in the sandbox.
