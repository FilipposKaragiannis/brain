bump: patch

- Health, the jobs and their locks work where ps cannot run, as in a sandbox that refuses the
  setuid /bin/ps on macOS. They fall back to pgrep for the command lines, lsof for a parent and
  python for a process group, so a live run, job or host session is no longer taken for dead: a
  job's lock no longer reads as stale, `jobs.sh run` no longer starts a second run beside one
  still going, `jobs.sh status` shows it running, health lists the processes instead of judging
  no run, and a run records the host session that started it.
