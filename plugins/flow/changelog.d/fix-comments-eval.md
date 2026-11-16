bump: patch

- The comments job starts each pass in the item's worktree, or the main worktree when the item
  holds none. Since Claude Code 2.1.323 a sandboxed session commits only in the worktree it
  started in, so a pass started in the main worktree could fix a thread but never commit, push
  or reply.
- comments says so when run by hand from elsewhere: it names the failed commit in the report
  instead of looking for a way around the sandbox.
