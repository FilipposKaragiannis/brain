bump: patch

- The formatter, comment and protected-file hooks read staged file names NUL-separated from git
  and treat each as data. A name with a space, a quote, `$( )`, a backtick, a newline or a leading
  dash reaches the formatter as one argument and can no longer run a command.
- `{files}` in a `format` command now stands for `"$@"`: the command runs as `sh -c <command> sh
  <names>`. Write `for f in {files}; do ... "$f" ...; done`; a `{files}` inside a nested
  `sh -c '...'` no longer sees the names.
