bump: patch

- Flow finds the main worktree once per working folder and checks git once per command, and
  hands both to the scripts it starts. A config read no longer lists the worktrees each time,
  which cuts the listings of one `new.sh` from 11 to 1.
