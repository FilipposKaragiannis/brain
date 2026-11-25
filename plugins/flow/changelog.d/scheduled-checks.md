bump: minor

- A project runs its own checks on a schedule. Each key under `jobs.checks` in
  `.flow/config.yaml` names a check with a `command` and a `schedule` (`every 30m`, `daily 02:00`
  or `weekly sun 03:00`, with no args). The new check job runs it as the schedule `check-<name>`
  from a clean checkout of the base under `<flow home>/check-runs/<name>`, never a claimed
  worktree, and `jobs.sh` status, history, logs, run, stop, pause and install take it as any
  schedule. Run flow:init to install the `.flow/jobs/check.sh` wrapper.
- A check that fails after a pass files one bug through `scripts/new.sh bug`, so
  `adapters.bug` picks the tracker. Its body holds the command, the base commit, the exit code and
  the last 40 lines of the output, cut to 8000 bytes and indented, so a `base:` line in it sets no
  base for the bug; on a public tracker that tail is public. A
  check that stays broken files no second bug, and its run says `still failing, bug <id>`; the
  next fail after a pass files a new one. A bug the tracker refuses is said in the run's line and
  filed at the next fail. Whether a check passed last lives in `<flow home>/log/check-<name>.state`.
- `init.sh --check` names each check that cannot run as a gap, with its line in
  `.flow/config.yaml`: a name that is not a lowercase letter then lowercase letters and digits, an
  entry with no command or no schedule, a schedule it cannot read or one with args, a command
  starting with `[`, an entry or `jobs.checks` itself set as a value, a `base` that is no valid
  branch name while a check is set, and a `jobs.schedule.check-<name>` key, which sets no check.
  `jobs.sh run` and `install` refuse the same, and the check job refuses such a base before git
  sees it.
