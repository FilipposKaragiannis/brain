bump: patch

- Verify hands the changed file names to a format or mutation command as separate arguments, read
  NUL-separated from git. `{files}` outside quotes is the names as arguments and inside quotes the
  names escaped for the nested shell, as in the commit hooks; a name never becomes command text.
  A deleted file is not passed, and a command that is empty or cannot take a name is a failed
  check with its reason.
