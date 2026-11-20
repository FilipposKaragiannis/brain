bump: patch

- A session a person started that has been idle for `jobs.comments.idle_session` (30m) no longer
  keeps the comments job out of a worktree with nothing uncommitted in it. One idle session held
  a PR's comments for hours. With an uncommitted change in the tree the pass still stays out.
- A session running a shell command reads as busy and one waiting on its user as idle. Both read
  as a session with no status before, shown as "running" for its whole age.
- A comments run that names its PR prints that it waits for a free pass slot, and the runs that
  hold the slots. The wait was written to the log only, so a run by hand looked hung.
- The log line of the failed pass that reaches `jobs.comments.max_failures` says the job stops
  trying the PR. It said the next run would try again.
