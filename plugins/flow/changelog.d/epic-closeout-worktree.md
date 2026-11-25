bump: patch

- An epic with an epic branch closes out in a pool worktree on that branch, at the tip the remote
  holds, set up like any other pool worktree (`worktree_setup` runs again when a
  `worktree_setup_paths` file changed) and based on the branch the epic started from. The brief
  names the epic branch, so `verify.sh` checks the epic's work instead of the main checkout. The
  worktree is released whatever the closeout's outcome. An epic with no epic branch closes out in
  the main checkout as before.
- `steward.sh claim-tip <item> <branch> [--base <branch>]` claims a pool worktree on a branch the
  remote holds, at its remote tip. A local copy behind the tip moves up to it; one ahead of it,
  diverged from it or checked out in another worktree is refused with why, exit 4. So is a
  closeout whose remote cannot be asked for the epic branch.
