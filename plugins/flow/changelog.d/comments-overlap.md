bump: minor

- Comments runs overlap: a run starts while another is alive, each under its own
  `comments-<pid>.lock`, and skips a PR whose lock another pass holds. `jobs.sh run comments` starts
  a run beside a live one; other jobs still refuse. intake and retro keep their shared lock.
- `jobs.comments_workers` now caps the passes live at once across all runs, through a slot pool in
  `log/comments.slots/`. A pass holds a slot for its host session only and waits for a free one;
  it never skips a PR for lack of a slot. A run given `--workers N` may use slots up to N.
- No comments pass runs forever: one still running at the new `jobs.comments.pass_limit` (default
  1h) is stopped with what it started and counts as failed, so the next run tries it again and it
  counts toward `jobs.comments.max_failures`. A bad value stops the run at its start, exit 2.
- A PR named by hand that the flow did not open takes `pr:<number>.lock`, so no two passes work it
  at once. Every schedule of the job (comments, comments-<label>) shares one seen record per PR
  under `comments.seen/`, and each run keeps its own target and gated lists.
- Upgrading needs no config edit. `jobs.comments_workers` keeps its name and default of 1.
  `jobs.comments.pass_limit` is new and optional, 1h when unset; the console shows it under the
  Comments job. `init` never rewrites an existing config, so its new commented `pass_limit` line
  shows only in the config a new project gets.
- An older version leaves files behind that nothing reads; they are harmless and safe to delete:
  `log/comments-<label>.seen/` (a labelled schedule makes at most one extra pass per PR, and its
  fail counts start again), a stale `log/comments.shared.lock`, and `log/comments.targets` or
  `log/comments.gated`. A stale `comments.lock` or `comments-<label>.lock` is removed by the next
  run of its schedule.
- A run of the older version still alive during the upgrade takes no pass slot, so the cap across
  runs holds only once it ends.
