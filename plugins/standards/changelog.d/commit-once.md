bump: minor

- An agent's commit runs the formatter and each gate once with `-a`, a pathspec (`-o`, `-i`) or a
  `git add` earlier in the same command, not only on a plain `git commit`. The agent hook records
  the content the commit will hold; git's `pre-commit` and `commit-msg` skip that same content.
- An edit to any tracked file between the agent hook and git's hooks runs them again.
- A commit the hook cannot predict (`-p`, `--interactive`, `--pathspec-from-file`, git options
  before `commit`, a quoted or globbed path, an earlier `cd` or git call other than `git add`)
  or a message in a heredoc runs them twice, as before.
