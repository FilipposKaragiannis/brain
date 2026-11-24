bump: patch

- The agent hooks on a Bash call that is no commit or push start no git and read no config, except
  `check-gates`, which reads only the gates that carry `forbid` or `forbid_run`, and nothing when
  the project has none. Before, every hook ran `git --version` on load and `check-gates` read every
  field of every gate first, so each Bash call waited about 0.2 s on the hooks; it now waits about
  0.15 s with a forbid gate and 0.1 s without one.
- A script that sources `hooks/lib.sh` and calls git calls `use_working_git` first, which picks
  Xcode's git where the macOS shim is broken.
