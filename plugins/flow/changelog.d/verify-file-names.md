bump: patch

- Verify hands the changed file names to a format or mutation command as separate arguments, read
  NUL-separated from git. `{files}` outside quotes is the names as arguments and inside quotes the
  names escaped for the nested shell, as in the commit hooks; a name never becomes command text.
  A deleted file is not passed, and a command that is empty or cannot take a name is a failed
  check with its reason.
- `{files}` is accepted in two forms: as an unquoted word of its own in the command, or as an
  unquoted word of its own in the script of a `sh -c` or `bash -c` that starts a command. A word
  ends at a blank or at one of `; & | < > ( )` and a newline. Every other placement is refused, as
  a failed check whose message names the accepted forms. To pass the names into any other
  construct, write `"$@"` there and put `{files}` as the last word of the command, as in
  `sh -c '... "$@"' sh {files}`.
- An escaped quote inside the nested shell's quotes no longer moves a later `{files}`, and any run
  of spaces and tabs separates the shell, `-c`, the script and `{files}`. A language with a format
  command and no extensions is a failed check, and a changed file name with a newline still
  matches the paths of a gate or a test command and is one entry in `changed_files`.
