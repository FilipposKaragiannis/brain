bump: minor

- `worktree_create` in `.flow/config.yaml` names the command that makes a flow worktree in place
  of `git worktree add`: a grown, added or recreated pool worktree and a `tmp add` phase worktree.
  `{path}` is the new folder and `{base}` the ref it starts from, written bare: `sh -c` gets them
  as `"$1"` and `"$2"`, so no value is read as shell. It runs from the main worktree with its
  output on stderr, and flow then puts the worktree on its branch. Unset, nothing changes.
- `worktree_remove` names the command that removes a `tmp remove` worktree in place of
  `git worktree remove`; flow then removes git's record of that worktree alone, when the command
  left it, and deletes its branch when it is `flow/<its folder under .flow/tmp>`. Pool worktrees
  are still never removed.
- A command with no `{path}`, or with a placeholder inside quotes or after a backslash, is
  refused before it runs, exit 2, and `init --check` names it as a gap. `init` writes both keys
  commented out.
- `tmp remove` refuses, exit 2, a path that is not a worktree git lists under `.flow/tmp`, the
  main or a pool worktree, a worktree whose `.git` is missing or broken, a locked one and any
  path while `.flow/tmp` is a symlink, and resolves a relative path from where it runs. It
  refuses, exit 3, a change in a submodule even when `.gitmodules` tells `git status` to ignore
  it. `tmp add` refuses, exit 2, a phase with a character other than a letter, a digit, `.`, `_`
  or `-`, one that makes no valid branch name (one holding `..`), and a phase whose branch or
  folder already exists.
- A pool that cannot grow because the worktree cannot be made now says so, with the command's or
  git's output, and exits 1. It used to say the pool was at `pool_max` and exit 3, which sent
  `next` on to another item instead of naming the failure.
