bump: patch

- The shell helper that expands `{files}` in a configured command is shared with flow, so verify and
  the commit hooks read the placeholder the same way.
