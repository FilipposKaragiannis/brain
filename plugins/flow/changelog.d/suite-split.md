bump: patch

- The checks of `tests/run.sh` live in 16 suite files by area, each of which runs alone, such as
  `sh plugins/flow/tests/health.sh`. `run.sh` takes no argument and hands the whole run to the
  suite runner once; `run.sh inline` and `run.sh verify` are gone.
- The worktree check that ran `git worktree remove -q` now runs it without `-q`, a switch git does
  not have, so the pin worktree is removed.
