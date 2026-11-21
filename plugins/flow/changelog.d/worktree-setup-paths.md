bump: minor

- A pool worktree whose dependencies went stale is set up again. The new optional config key
  `worktree_setup_paths` lists globs of the files whose change means `worktree_setup` must run
  again, such as a lockfile. The steward records the commit each worktree's setup last ran at
  (`.flow/setup-commit` in the worktree: on add, on recreate and on `steward.sh setup`), and a
  claim runs `worktree_setup` again before it hands the worktree out when a matching file differs
  between that commit and the worktree's HEAD, then records the new commit. A worktree with no
  record counts as changed. Unset, nothing changes.
- A setup command that fails at a claim is reported and the worktree is handed out, as after a
  failed setup at add. A setup removes the record when it starts and writes the commit it
  started at only when every command passed, so after a failed or cut-off setup the next claim
  tries again, even at the same commit. While a setup runs the
  worktree holds `.flow/setup-pid`: `health` does not release that claim as empty, and another
  claim of the item (`steward.sh claim`, or `next`) waits for the setup before it prints the
  path. The init template documents the key in a commented line beside `worktree_setup`.
