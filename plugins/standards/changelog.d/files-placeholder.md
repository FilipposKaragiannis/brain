bump: patch

- The formatter hook reads `{files}` through the same shared helper as flow's verify, so the two
  cannot drift. A `{files}` that is not an argument word of its own, outside quotes or unquoted in
  the quoted script of a `sh -c` or `bash -c` that starts a command, now fails the format check with
  its reason instead of being guessed at, so a file name is never read as shell. The shell, `-c`
  and the script are read as words split by any run of spaces and tabs.
