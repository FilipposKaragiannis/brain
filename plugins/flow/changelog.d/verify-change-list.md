bump: patch

- Verify no longer passes when it cannot list every changed file. A comparison base that cannot
  be resolved, or a git listing of changes that fails (the diff from the base, the diff of
  uncommitted changes or the listing of untracked files), is a failed `changed files` check that
  names the cause, and git's error reaches the verify log. In that state every build, test and
  gate command with paths runs, no kept test pass is reused, and `feel_test` is true when
  `feel_test_paths` is set. A format or mutation command with `{files}` that finds no file says
  it looked only among the files verify could list.
