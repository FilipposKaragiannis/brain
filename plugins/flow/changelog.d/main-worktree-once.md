bump: patch

- Flow finds the main worktree once per working folder and checks git once per command, and
  hands both to the scripts it starts. A config read no longer lists the worktrees each time,
  which cuts the listings of one `new.sh` from 11 to 1. A git put first on `PATH` for one
  script is still asked there, and `verify.sh` finds the main worktree once more after it moves
  to the repository root.
