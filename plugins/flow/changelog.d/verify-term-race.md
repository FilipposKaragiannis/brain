bump: patch

- A verify run under dash stopped by TERM or INT just after it made its first temp file no longer
  leaves that file behind: the cleanup is set before the temp files exist.
