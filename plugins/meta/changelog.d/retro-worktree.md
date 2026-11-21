bump: patch

- The retro skill applies its marketplace changes in a throwaway worktree cut from the remote's
  default branch, pushes the branch, opens the PR and removes the worktree. It never switches the
  branch of the marketplace checkout or edits a file in it. Before, it worked on `retro/<date>` in
  the checkout the prompt named, which could be the one the owner works in and the jobs run from.
- It runs the tests its edits touch, the way the worktree's testing guide says, and never the
  whole `tools/test.sh`: CI runs that on the PR.
