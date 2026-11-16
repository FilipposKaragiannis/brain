bump: patch

- verify runs where ps cannot run, as in a sandbox that refuses the setuid /bin/ps on macOS. The
  detached run no longer stops before its first check, and --wait no longer reads a run still
  going as one that died: it falls back to pgrep to see whether the run still goes.
- On Linux, where pgrep lists a zombie, that fallback reads the process state from /proc, so a
  verify run that has ended but is not yet reaped no longer holds steward stop or release for the
  whole wait.
- The PR step opens the PR with `gh pr create` and the whole body at once, for a local item too.
  The tracker only records the PR, and a pushed branch is no PR.
