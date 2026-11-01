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
| the runs of one schedule | `"$P/scripts/jobs.sh" history <name> [N]` |
| what a schedule said | `"$P/scripts/jobs.sh" logs <name> [N]` |
| run one now | `"$P/scripts/jobs.sh" run <name>` |
| run `next` once on another model or effort | `.flow/jobs/next.sh <host> [item] --max-steps N [--workers N] --model <name> --effort <level> &` |
| end a run now | `"$P/scripts/jobs.sh" stop <name>` |
| hold a schedule, or all, without unscheduling | `"$P/scripts/jobs.sh" pause <name\|all>`, then `resume` |
| schedule the jobs, or change a schedule | set `jobs.schedule.<name>` in `.flow/config.yaml`, then `"$P/scripts/jobs.sh" install [name]` |
| run one job on two schedules (a claude `next` and a codex `next`) | add `jobs.schedule.next-codex: every 30m codex --max-steps 15`, then `"$P/scripts/jobs.sh" install next-codex` |
| remove a schedule | `"$P/scripts/jobs.sh" uninstall [name]`, also for one the config no longer names |
| end one item's run, or start a dead one again | `"$P/scripts/steward.sh" stop <item>`, `"$P/scripts/steward.sh" resume <item>` |
| the pool looks stuck, or what the health job would do | `"$P/scripts/steward.sh" health --dry-run`; to act, `"$P/scripts/jobs.sh" run health` |

1. Show `status` and `history` tables as they print. Under the table, one line per job that
   failed or waits on a gate, saying what to do.
2. A schedule is `every 30m [args]`, `daily 02:00 [args]` or `weekly sun 03:00 [args]`; the
   args go to the job (`next`: `--workers 2 --max-steps 15`). Args that begin with `claude` or
   `codex` run that schedule on that host instead of `jobs.host`; another plain word there is
   refused as a misspelled host, while an item id (`gh#12`, `local:task/3`) or an option is an
   arg as before. Edit the config, show the diff, then install.
3. A schedule's name is a job (`next`, `comments`, `intake`, `retro`, `health`) or a job, a dash
   and a label of a lowercase letter then lowercase letters and digits (`next-codex`,
   `next-gh81`), so one job runs on several schedules, each with its own args and host. Each one
   is its own launchd agent (`com.<repo>.flow.<name>`), log, lock, pause and history, and its
   runs are `<name>` in `runs.jsonl`. Two `next` schedules run side by side and never pick the
   same item. The schedules of any other job take turns: one skips while another of its job runs,
   as they share its state. `install` refuses any other name (`next_codex`, `next-1`), exit 2. `all` is every
   schedule the config names.
4. `stop` ends the agent sessions mid-step. Confirm it first: the item stays where its last
   step left it, and the next run picks it up again.
5. Pause is the safe hold: a paused schedule's runs exit at once and show as `paused`, the
   schedule stays loaded, and a running run finishes. Pausing `next` pauses every worker of it, a
   worker started by hand included; it leaves `next-codex` running, which has its own pause.
6. To split `next`'s workers across hosts, set `jobs.workers` (`{claude: 1, codex: 2}`) and
   drop `--workers` from `jobs.schedule.next`; `install` refuses the two together.
   `jobs.workers` is the plain `next` schedule's alone: a named one (`next-codex`) runs
   `--workers N` from its args on its own host, or one worker.
7. A schedule removed from the config while installed stays loaded: `status` lists it with
   `not in the config: jobs.sh uninstall <name>`, and `uninstall <name>` removes it.
8. `next` also takes `--model <name>` and `--effort <level>` for one run started by hand, from
   the main worktree, in the background: that run's steps with no agent use them instead of
   `jobs.<host>.model` and `jobs.<host>.effort`, and the config is left as it is, so the
   schedule's runs keep the pair. They apply on the host named: its run, or its workers (a
   `jobs.workers` worker on the other host keeps its own pair). Empty or absent keeps the pair.
   An effort the host does not take is refused, exit 2, before the run touches the tracker.
9. Every job takes `--model <name>` and `--effort <level>`, in a schedule's args too
   (`jobs.schedule.intake: daily 02:00 codex --model gpt-6-luna --effort low`). They replace
   `jobs.<host>.model` and `jobs.<host>.effort` for that run's sessions: comments, intake and
   retro for their own sessions, health for the run it resumes. Empty or absent keeps the pair.
   An effort the host does not take fails the run at its start, exit 2, as a failed run.

Facts to answer with:
- On macOS each job is a launchd agent that loads at login. It runs while the owner is logged in
  and the Mac is awake. A run missed while asleep starts on wake; one missed while the Mac is off
  is skipped. Pause survives a restart.
- Each `next` run and each `health` run first frees the worktrees whose PR was merged or whose
  item was closed (`steward.sh sweep`): the merge gate clears and the item closes, without the
  owner, within one health cycle.
- A `next` run with `--workers` starts the workers and ends; it does not wait for them. A worker
  still busy is skipped by the next schedule, a free one starts, so one long build never holds
  the others. `--wait` stays until every worker ends. The launchd agent needs
  `AbandonProcessGroup`, or launchd ends the workers with the run; an agent installed before
  1.21.1 lacks it, and `status` says `reinstall: jobs.sh install <job>` until it is reinstalled.
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
  still busy from the last schedule is skipped, which shows as `skipped`. `--worker` takes only
  a number, so every worker shows in `status` and obeys the pause. A named schedule's workers are
  `<name>-<n>` (`next-codex-1`).
- `install` writes a named schedule's command with `--as <name>`
  (`.flow/jobs/next.sh codex --as next-codex --max-steps 15`): the job runs under that name.
- `jobs.workers` in `.flow/config.yaml` (`{claude: 1, codex: 2}`, or one host per line under it)
  starts each worker of a scheduled `next` run on its own host, numbered across the hosts,
  claude first: `next-1` on claude, `next-2` and `next-3` on codex. `status` lists each worker
  under the table with its host and its state or last run. `--workers N` given by hand still
  starts N on the host named. A host other than claude or codex, or a count that is not a whole
  number, stops the run (exit 2, recorded so `status` shows it); `run` and `install` refuse it.
- Each `status --json` row has `name` (the schedule), `job` (the script it runs: `next` for
  `next-codex`), `host` (its host word, else `jobs.host`), `args` (without the host word), and
  `configured`: false for a schedule installed here that the config no longer names, true
  otherwise. `status --json` keeps `last` as the newest run that did something. `last_run` is the newest
  run of any kind and `latest` the newest of each outcome (work, gate, quiet, skipped, paused,
  failed), each with `reason`: why it ended so, such as the live run a skip found. Each run and
  each worker carries the `host` it ran on.
- The host is `jobs.host` (claude, the default, or codex), except for a schedule whose args begin
  with a host and for the plain `next` schedule's workers when `jobs.workers` is set. The sessions a job starts (comments,
  intake, retro) take the model and effort of that host's pair: `jobs.claude.model` and
  `jobs.claude.effort` reach `claude` as `--model` and `--effort`; `jobs.codex.model` and
  `jobs.codex.effort` reach `codex exec` as `-m` and `model_reasoning_effort`. Each value goes as
  written, so it names a model that host knows; empty or missing is the host's default. A Claude
  effort is low, medium, high, xhigh or max; a Codex one low, medium, high or xhigh. A `jobs.host`
  other than claude or codex stops every job at its start (exit 2, the line to fix in the
  error). A bad effort stops comments, intake and retro as a failed run that `status` and
  `history` show, and `next` before it claims an item; `run` and `install` refuse both. `next`
  (and the run `health` resumes) runs a step with an agent on the roster's model and effort, and
  a step with none (design, implement, review, explain) on the host's pair, or on the
  `--model` and `--effort` of a run started by hand with them.
- Each step session of `next` is a line in `.flow/log/runs.jsonl` with its item, step, model,
  effort, and the usage and cost the host reported. A session that fails on a spend limit or an
  auth error raises the escalation gate on its item, naming the cause, and stops the host: no
  job starts a session on it until that gate clears (`gate.sh clear <item>`, or
  `gate.sh clear <host>` for a stop outside any item's run).
- `jobs.model` and `jobs.effort` are deprecated (read only while the host has no `jobs.<host>`
  map, with the old name mapping for Codex and one warning in the job's log). To migrate, move
  them under `jobs.claude` and give `jobs.codex` Codex names.
- Never claim a schedule exists unless `status` shows it `scheduled`.
