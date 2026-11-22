bump: patch

- Verify no longer passes when it cannot list every changed file. A comparison base that cannot
  be resolved, or a git listing of changes that fails (the diff from the base, the diff of
  uncommitted changes or the listing of untracked files), is a failed `changed files` check that
  names the cause, and git's error reaches the verify log. In that state, and when a changed file
  name holds U+001F (already a failed `changed files` check), every build, test and gate command
  with paths runs, no kept test pass is reused, and `feel_test` is true when `feel_test_paths` is
  set, with verify.md saying a change there cannot be ruled out. A format or mutation command with
  `{files}` that finds no file says it looked only among the files verify could list.
- Verify lists the changed files of a repository that tracks a file named `HEAD` at its root. Git
  read that name as both a revision and a file and refused the diffs, so those changes went
  unlisted.
- `feel_test` is true for a changed file under a `feel_test_paths` glob such as
  `ui/src/**/*.tsx` even when the glob also names an unchanged file in the worktree; the shell
  no longer expands the glob against the folder first.
