---
name: jobs
description: Run and watch the scheduled flow jobs on this machine (next, comments, intake, retro, health). Shows each job's schedule, state, last run with its length and result, next run and last week's counts; shows a job's run history or log; runs one now, stops a running one, pauses and resumes, and installs or removes the schedule from .flow/config.yaml. Use when the owner asks what the jobs are doing, when a job last ran or runs next, or to start, stop, pause, resume or schedule one, or when the pool looks stuck: worktrees claimed, nothing moving, a run that is not running, a gate nobody answers.
disable-model-invocation: true
---

The schedule is the owner's machine, so every change here is theirs to ask for.

Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex
the path `codex plugin list` prints for `flow`). Run from the main worktree.

| The owner asks | Run |
|---|---|
| what the jobs are doing, when they run | `"$P/scripts/jobs.sh" status` |
| the runs of one job | `"$P/scripts/jobs.sh" history <job> [N]` |
| what a job said | `"$P/scripts/jobs.sh" logs <job> [N]` |
| run one now | `"$P/scripts/jobs.sh" run <job>` |
| end a run now | `"$P/scripts/jobs.sh" stop <job>` |
| hold a job, or all, without unscheduling | `"$P/scripts/jobs.sh" pause <job\|all>`, then `resume` |
| schedule the jobs, or change a schedule | set `jobs.schedule.<job>` in `.flow/config.yaml`, then `"$P/scripts/jobs.sh" install [job]` |
| remove a schedule | `"$P/scripts/jobs.sh" uninstall [job]` |
| the pool looks stuck, or what the health job would do | `"$P/scripts/steward.sh" health --dry-run`; to act, `"$P/scripts/jobs.sh" run health` |

1. Show `status` and `history` tables as they print. Under the table, one line per job that
   failed or waits on a gate, saying what to do.
2. A schedule is `every 30m [args]`, `daily 02:00 [args]` or `weekly sun 03:00 [args]`; the
   args go to the job (`next`: `--workers 2 --max-steps 15`). Edit the config, show the diff,
   then install.
3. `stop` ends the agent sessions mid-step. Confirm it first: the item stays where its last
   step left it, and the next run picks it up again.
4. Pause is the safe hold: a paused job's runs exit at once and show as `paused`, the schedule
   stays loaded, and a running run finishes.

Facts to answer with:
- On macOS each job is a launchd agent that loads at login. It runs while the owner is logged in
  and the Mac is awake. A run missed while asleep starts on wake; one missed while the Mac is off
  is skipped. Pause survives a restart.
- Each `next` run first frees the worktrees whose PR was merged or whose item was closed
  (`steward.sh sweep`): the merge gate clears and the item closes, without the owner.
- An idle run (nothing ready, no new notes, no open PR) ends at once and spends no model time.
- Each `retro` run, quiet or not, commits `lessons.jsonl` and `retros.log` on the base branch and
  pushes them, as `intake` does the notes, so a cloud session reads the same lessons
  (`retro.commit: false` turns it off).
- The `health` job (every 15 minutes in the config `flow:init` writes) checks each claim and spends
  no model while all is well: it clears a dead run's record, releases an empty claim, resumes
  cut-off work up to `jobs.health.max_resumes` times, then raises an escalation gate, syncs clean
  task branches (never rewriting history or resetting work; it pushes only with
  `jobs.health.push: true`), merges the base into a branch more than `jobs.health.behind_base`
  commits behind it, with no PR and no gate, hands a merge that conflicts or a diverged branch to the
  `sync` step of the item's next run, reminds on gates older than
  `jobs.health.gate_reminder` and says when the pool is full. `notify.health: false` mutes it.
- A worker of `next` (`next-1`, `next-2`) is its own run with its own lock and log; a worker
  still busy from the last schedule is skipped, which shows as `skipped`.
- The host is `jobs.host` (claude, the default, or codex). The sessions a job starts (comments,
  intake, retro) take the model and effort of that host's pair: `jobs.claude.model` and
  `jobs.claude.effort` reach `claude` as `--model` and `--effort`; `jobs.codex.model` and
  `jobs.codex.effort` reach `codex exec` as `-m` and `model_reasoning_effort`. Each value goes as
  written, so it names a model that host knows; empty or missing is the host's default. A Claude
  effort is low, medium, high, xhigh or max; a Codex one low, medium, high or xhigh. A `jobs.host`
  other than claude or codex stops every job at its start (exit 2, the line to fix in the
  error). A bad effort stops only comments, intake and retro, as a failed run that `status`
  and `history` show; `run` and `install` refuse both. `next` runs each step with the roster's
  model and effort instead, and so does the run `health` resumes, so neither reads the pair.
- `jobs.model` and `jobs.effort` are deprecated (read only while the host has no `jobs.<host>`
  map, with the old name mapping for Codex and one warning in the job's log). To migrate, move
  them under `jobs.claude` and give `jobs.codex` Codex names.
- Never claim a schedule exists unless `status` shows it `scheduled`.
