bump: patch

- The formatter hook reads `{files}` through the same shared helper as flow's verify, so the two
  cannot drift, and a file name is never read as shell. `{files}` is accepted in two forms: as an
  unquoted word of its own in the command, or as an unquoted word of its own in the script of a
  `sh -c` or `bash -c` that starts a command. A word ends at a blank or at one of `; & | < > ( )`
  and a newline. Every other placement is refused, as a failed format check whose message names
  the accepted forms. To pass the names into any other construct, write `"$@"` there and put
  `{files}` as the last word of the command, as in `sh -c '... "$@"' sh {files}`. The shell, `-c`
  and the script are read as words split by any run of spaces and tabs.
