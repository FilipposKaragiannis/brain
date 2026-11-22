bump: patch

- Verify hands the changed file names to a format or mutation command as separate arguments, read
  NUL-separated from git. `{files}` outside quotes is the names as arguments and inside quotes the
  names escaped for the nested shell, as in the commit hooks; a name never becomes command text.
  A deleted file is not passed, and a command that is empty or cannot take a name is a failed
  check with its reason.
- A `{files}` that sits inside a quote inside another quote is a failed check with its reason, since
  its names could not stay data through two shells; pass them on as arguments, as in
  `sh -c '... "$@"' sh {files}`. A language with a format command and no extensions is a failed
  check, and a changed file name with a newline still matches the paths of a gate or a test command.
