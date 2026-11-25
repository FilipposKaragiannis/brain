bump: minor

- A project runs its own checks on a schedule. Each key under `jobs.checks` in
  `.flow/config.yaml` names a check with a `command` and a `schedule` (`every 30m`, `daily 02:00`
  or `weekly sun 03:00`, with no args). The new check job runs it as the schedule `check-<name>`
  from a clean checkout of the base under `<flow home>/check-runs/<name>`, never a claimed
  worktree, and `jobs.sh` status, history, logs, run, stop, pause and install take it as any
  schedule. Run flow:init to install the `.flow/jobs/check.sh` wrapper.
