bump: patch

- Verify hands the changed file names to a format or mutation command as separate arguments, read
  NUL-separated from git. `{files}` outside quotes is the names as arguments and inside quotes the
  names escaped for the nested shell, as in the commit hooks; a name never becomes command text.
  A deleted file is not passed, and a command that is empty or cannot take a name is a failed
  check with its reason.
- A `{files}` that is not an argument word of its own, outside quotes or unquoted in the quoted
  script of a `sh -c` that starts a command, is a failed check with its reason: one in nested
  quotes, joined to other text, in command position, after a `$(`, `${`, backtick, `#` or `<<` the
  scanner does not follow, or in a command that leaves a quote open. Pass the names on as arguments,
  as in `sh -c '... "$@"' sh {files}`. An escaped quote inside the nested shell's quotes no longer
  moves a later `{files}`. A language with a format command and no extensions is a failed check, and
  a changed file name with a newline still matches the paths of a gate or a test command and is one
  entry in `changed_files`.
