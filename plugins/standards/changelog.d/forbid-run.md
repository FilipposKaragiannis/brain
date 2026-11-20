bump: minor

- A project gate takes `forbid_run`: it blocks a command that starts one of the programs named,
  as written or by a longer path, and through a shell, `env`, `exec`, `nohup`, `nice` or
  `timeout` too. A command that only names the path (`git add`, `sed`, `grep`, `sh -n`) passes.
  `forbid` matches a text anywhere in the command, which blocks reading or staging a script
  whose path it names; it stays for a verb passed as an argument.
