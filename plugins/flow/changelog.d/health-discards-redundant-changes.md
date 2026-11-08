bump: minor

- The `health` job cleans a free pool worktree whose uncommitted changes are already in the base
  branch's history. `scripts/_redundant.py` checks each changed path. Its content and mode, both
  staged and on disk, must be a version the base's history gave that same path, or the path is
  deleted. The worktree's commit must also be in the base. The first run that finds such changes
  names them once. The next run discards them if they are unchanged and no session works there.
  It checks again, restores only the checked paths and removes only the checked untracked files,
  so `.flow/` is never touched. It notifies the owner, and a claim can use the worktree again. A
  free worktree once sat for four days holding a stale index from before a squash merge. Health
  said so once, and the pool ran one worktree short.
- Changes with anything of their own stay. A conflict, a submodule, an untracked file or a
  version the base never had all count, as do more than 200 changed paths, a git command in
  progress or a file that cannot be hashed. Each file is hashed on its own, so any file name is
  safe, and from its raw bytes, so a clean filter or an end-of-line rule cannot hide bytes only the
  disk holds. The health line now names the first such path: `wt-2 is free but has uncommitted
  changes, so no claim can use it: the disk version of README.md is not in origin/main`.
