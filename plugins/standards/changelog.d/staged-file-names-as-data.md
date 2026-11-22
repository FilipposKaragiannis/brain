bump: patch

- The formatter, comment, gate and protected-file hooks read staged file names NUL-separated from
  git and treat each as data. A name with a space, a quote, `$( )`, a backtick, a newline or a
  leading dash reaches the formatter as one argument and can no longer run a command.
- `{files}` in a `format` command stands for `"$@"`: the command runs as `sh -c <command> sh
  <names>`. A `{files}` inside quotes, as in `sh -c 'for f in {files}; ...'`, still sees the names:
  each is backslash-escaped for the nested shell. A name with a newline in such a command blocks.
- A failing formatter's report lists the files it was given.
- The comment hook takes file names from git, never from the diff text, so a name with a tab,
  carriage return, newline, backslash, quote or non-ASCII letter keeps its own content lookup. It
  reads staged content without following symlinks, and blocks when it cannot read the diff.
