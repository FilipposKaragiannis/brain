# flow

## 1.13.1 (2026-10-22)

- `next.sh` no longer stops at "no free worktree" while an item that already holds a claim is ready.
  A pick that finds the pool full skips the items that need a new worktree and takes the first one
  that holds a claim, so a full pool keeps working through its claimed items. It exits 3 only when
  every ready item left needs a new worktree. Naming an item still exits 3 when it has no room.

## 1.13.0 (2026-10-22)

- A `health` job checks the worktree pool and the gates every 15 minutes and spends no model while
  all is well. `steward.sh health [--dry-run] [--host H] [--wait]` does the work, so it also runs
  by hand; `jobs/health.sh` adds the lock, the pause and the log, and `jobs.sh` lists, runs,
  pauses and schedules it like the others (`jobs.schedule.health`; the config `flow:init` writes
  sets `every 15m`). Per claimed worktree, in order:
  - Heartbeat. A run is alive when the pid its record names still runs the unattended loop or the
    host session, or an agent works in the worktree, or a process names the worktree or the item.
    A record with no live process for `jobs.health.grace` (10m) is a dead run: the record goes.
  - An empty claim (no run, no gate, a clean tree, no commit past the base, no step result, quiet
    for the grace) is released with `release`, never `--force`.
  - Work with a dead run is resumed through `run-unattended.sh` with the item, once per run, at
    most `jobs.health.max_resumes` (3) times in a row while the step does not advance, then an
    escalation gate. The resumed step's brief carries a note. Nothing is reset, stashed or
    discarded.
  - Branch sync for a clean tree and no live run: fast-forward when only behind the remote branch,
    push when only ahead of one that exists (never a new remote branch, never forced). A diverged
    branch, or one more than `jobs.health.behind_base` (20) commits behind the base, is only
    flagged: a notification and a note in the item's reports that the next brief carries. A free
    worktree follows the base tip. A dirty or running worktree is never synced.
  - A gate pending past `jobs.health.gate_reminder` (24h) gets one reminder per interval.
  - A full pool that the last `next` run could not start in is said once, with who holds each
    worktree and why.
- Each fact is one line in the job log and in `events.log`; a state already said is not said again.
  Nothing to do is one `quiet:` line and no notification. The notify event is `health`;
  `notify.health: false` turns the notifications off.
- The run record carries the `pid` of its owner: the unattended loop (it exports `FLOW_RUN_PID`)
  or the host session that called `next.sh`. A record without one, from an older flow, is read by
  scanning the processes. Run `flow:init` again to get the loop that records it.
- The board prints `dead run` for a record with no live process instead of `running on <host>`,
  and a `## Health` section when a run is dead or a gate waits past the reminder.
- `notify.sh --event <name> --no-log <message>` skips the events.log line for a caller that logged it.
## 1.12.0 (2026-10-19)

- The retro job commits the lessons log. After each run, quiet or not, `lessons.jsonl` and
  `retros.log` are committed alone on the base branch in the main worktree and pushed, so a cloud
  session reads the same lessons. As with the notes: only when the main worktree is on the base
  branch, a file git ignores is left out and said, the push waits for the owner when the base has
  other unpushed changes, and a failed push is retried by the next run. `retro.commit: false`
  turns it off; the config `flow:init` writes names it.
- The commit and push both jobs share is `job_commit` in `jobs/_job.sh`; intake's commits and
  messages are as before.

## 1.11.0 (2026-10-19)

- `steward.sh sweep [--dry-run]` frees the worktrees whose work landed. A claimed worktree is
  released when its item is closed or its linked PR is merged. On a merge it clears the merge
  gate with the PR's URL and closes an item the merge left open, as a PR into an epic branch
  does. It deletes a squash-merged task branch only while the branch tip is the PR's head, so a
  commit made after the merge keeps the branch. It leaves alone a worktree with uncommitted
  changes, a run in flight, or an item it cannot read.
- The scheduled `next` job runs the sweep each time, after the tracker answers and before a
  worker claims. Merging on the host is now the whole answer to the merge gate.
- `comments.sh state` also prints `headRefOid`.

## 1.10.0 (2026-10-18)

- Intake has two new outcomes. `answered`: a question note is answered from the code and the
  docs, and the job appends the answer to `intake.answers` (default `answers.md` beside the
  notes) instead of filing an item. `dropped`: only with a reason the owner can check, appended
  to `intake.dropped` (default `dropped.md`). A row without its answer or reason is kept. No note
  is parked: `#parked` is a plain tag. Both pages are committed with the notes file, unless git
  ignores one: that page is left out and the notes file is still committed.
- A parsed note carries its title, tags, `^id` handle (a caret at the start or after a space),
  `#dup (see ^id)` and `rel:` handles, and what the ledger holds for those handles: each one's
  outcome, items and the reason it was dropped or done. They are read again before each session,
  so a note links the notes filed earlier in the same run. The skill maps the tags to issue
  types, files a `#dup` as a duplicate, drops a `#dup` of a dropped or answered note with a
  reason that names it, and links related items.
- Each intake session gets the tracker's issue types and area options (`vocabulary.sh` on
  GitHub). `new.sh --area` sets the `github.fields.area` issue field, or the local item's area;
  the skill picks the area from the note's section.

- How a note becomes an item is the project's: the outcome rules, the tag-to-type table, the
  area, size and priority rules and when a note needs the owner live in a rules file, which each
  session reads first. `intake.rules` names it, else `.flow/intake.md` when it exists, else the
  plugin's `skills/intake/rules.md`, flow's defaults: copy it to `.flow/intake.md` to change
  them. An `intake.rules` that names a missing file fails the run before any session.

## 1.9.0 (2026-10-18)

- The `jobs` skill and `scripts/jobs.sh` run and watch the scheduled jobs: `status` shows each
  job's schedule, state, last run with its length and result, next run and the last 7 days'
  counts; `history`, `logs`, `run`, `stop`, `pause`, `resume`. `install` writes and loads the
  schedule from `jobs.schedule.<job>` in `.flow/config.yaml` (`every 30m`, `daily 02:00`,
  `weekly sun 03:00`, then the job's args): launchd agents on macOS, the crontab lines
  elsewhere. `jobs.host` picks the host.
- Every job run is one line in `<flow home>/log/runs.jsonl`: start, length, exit and its last
  words, also for a run a live lock skips and a job that dies after it starts.
- A paused job's runs exit at once, before any tracker call or model spend, and the schedule
  stays loaded. The init config and hints, and `do`, point at the skill. Re-run `flow:init`.
- A schedule's args are checked (plain options and values only) and shell-quoted, and its times
  must exist; cron refuses an interval it cannot keep steady. A lock whose pid a restart gave to
  another process no longer counts as a running job, and the ledger rotates without losing a line.

## 1.8.0 (2026-10-17)

- Answer a gate on GitHub: a comment after the gate's comment that starts with `/answer` (alone:
  as recommended). The scheduled next job clears the gate with those words, reacts +1 and can
  pick the item in the same run. Only the authenticated user counts, or `github.answer_from`.
  The merge gate is not answered this way. Slack's gate notice says how.
- A cleared gate keeps its question and answer in the item's state, and the next step's brief
  shows them; before, the answer reached only a comment the next agent never read. A single
  GitHub read now always fetches the state comment, since an unstarted item has no flow label.
- `intake.notes` may be a path in the repository. A tracked notes file is committed alone and
  pushed after the run when the main worktree is on the base branch and nothing else is
  unpushed, so a cloud session reads the same notes; `intake.commit: false` turns it off.

## 1.7.0 (2026-10-17)

- A gate notification names the item by its id and title. Slack links it to the tracker and
  says how to answer; the desktop shows the title as the subtitle. The message keeps its lines.
- Ambiguity questions have one format, set in the step brief, the gate skill and intake:
  numbered, one per line, each followed by `Recommended:` with the agent's answer and why. The
  owner can reply "as recommended" or change one.

## 1.6.1 (2026-10-17)

- Unattended sessions start a skill as the owner would type it (`/flow:intake ...` on Claude,
  `$intake ...` on Codex) through `host_skill_prompt`, in the intake, comments and retro jobs
  and in the unattended loop's skill steps (design, implement, review, explain). Those skills
  are user-invoked only, so a prompt asking the model to invoke one was refused and the session
  did nothing. The loop template changed: re-run `flow:init`.
- Intake removes a note without touching the blank lines elsewhere in the file, and sets a
  parent only when the note names the epic, since a sub-item holds its epic open.

## 1.6.0 (2026-10-17)

- The intake job and skill: `jobs/intake.sh <host>` reads the next notes from `intake.notes`
  (at most `intake.batch`, default 10) and runs the `intake` skill in a fresh session per note,
  one after another. The skill files the note as a typed, sized item with a suggested priority
  in its notes (never the priority field), names the open item it duplicates, and gates a note
  that needs the owner with `ambiguity` and its questions. After each session the job records
  the note in a ledger and removes it from the notes file by its exact text; `--keep-notes`
  reads a file without changing it.
- `jobs.permission_mode` (`dontAsk`, the default, or `auto`) sets the Claude permission mode of
  every unattended session. Under `dontAsk` without an allow list a run cannot edit a file;
  `auto` lets the classifier allow the safe tools.

## 1.5.1 (2026-10-17)

- An item with open native sub-issues is not ready, so an epic is never picked for its closeout
  while its tasks are open; its project card shows In progress. The GitHub query reads each
  issue's sub-issue summary for it.

## 1.5.0 (2026-10-17)

- The GitHub adapter lists and reads issues through one paged GraphQL query: labels, native
  parent, blockers, issue type, issue field values and project cards in one call per page, not
  one per issue. `github.limit` defaults to 500 and the list says when it stops there.
- Kind comes from the issue type (Epic, Bug, else task) before the labels. A `Parent: #N` line
  with a colon names the parent too; the native sub-issue parent wins.
- Opt-in keys under `github:` in `.flow/config.yaml`: `types`, `fields.size`, `fields.priority`,
  `priority_order`, `ready_needs`, `project` and `status`. With them the size lives in the issue
  field instead of a `size:` label, `flow:new --type` names the issue type, an unstarted item
  lacking a `ready_needs` field is not ready, ready items go highest priority first (also on the
  board), and the project card's Status follows the flow state: gate Needs you, merge gate In
  review, a started step In progress, ready Ready, else Backlog.
- `adapters/github/sync.sh [id]` brings the project in step; `write-state` runs it for its item
  and the next job runs it once per schedule.
- The query asks for issue field values only when a field is configured, and for project cards
  only when `github.project` is set, so a login without the `read:project` scope still lists.

## 1.4.0 (2026-10-17)

- The wrappers under `.flow/` hold no path and no version. Each sources the new `.flow/plugin.sh`,
  which finds the installed plugin when the wrapper runs: `$FLOW_PLUGIN`, else the newest flow in
  the Claude plugin cache, else the newest in the Codex one (exit 2 when neither has it). A plugin
  update no longer changes committed files or leaves the wrappers on the old version, and a clone
  on another machine works as is. Run `init` once and commit `.flow/` to move a project over.
- The stamp's source hash leaves out the manifest, so a version bump alone is no drift.
- The session-start hook stays quiet when the plugin changed but the copies still match.

## 1.3.1 (2026-10-17)

- `init --check` reports missing Claude worktree hooks as a gap when the project has a `.claude`
  folder: `.claude/settings.json` (or `settings.local.json`) must name both
  `worktree-create.sh` and `worktree-remove.sh`. Init still only prints the entry; the file is
  the owner's.
- The session-start hook says so too, on every session, so a branch from before the flow was set
  up (no hooks in its settings) shows at once.

## 1.3.0 (2026-10-13)

- `steward.sh prune [--dry-run]` deletes the reports of closed items. Reports outlive the
  release, so they piled up in every worktree. It looks in the main worktree and every pool
  worktree, and keeps the folders of open items, of claimed items, of items it cannot read, and
  of folders that are not an item's (it names those). The steward skill lists it.
- A release of a closed item deletes its reports in every worktree, so `prune` is only for
  what was left before.
- `steward.sh reports <item>` prints the item's reports folder: the claimed worktree's, else the
  one that exists, else the main worktree's. Skills run outside `next.sh` (review, comments,
  explain, verify, test, pr, implement, plan) take it from there, so a standalone run no longer
  writes to a folder of its own naming (a bare `298` beside `gh-298`) or in the wrong worktree.
  An id that is not an item's fails with exit 2.

## 1.2.0 (2026-10-11)

- Gates in `.flow/config.yaml` take `paths`. `name: command` still always runs. A map with
  `command:` and `paths:` (globs) runs when a changed file matches one, else the report lists the
  gate as skipped.
- Slack: `FLOW_SLACK_WEBHOOK` in the environment supplies the webhook, so the URL stays out of
  the repository. `notify.slack_webhook` is the fallback.
- Mutation in `verify`: an empty `mutation` in `.standards/config.json` is off and shows as a
  skipped check. A command with `{files}` runs on the changed source files only and is skipped
  when none changed.
- `notify.idle: true`: the scheduled `next` job sends one notice when it finds nothing ready, then
  stays quiet until a run does work again. `notify.sh --event <name> <message>` sends a notice
  that is not a gate (no gate record).
- Parallel unattended runs. `jobs/next.sh <host> --workers N` starts N loops, each on its own
  ready item and worktree, each with its own lock and log (`next-1` ... `next-N`). A worker
  still busy from the last schedule is skipped. A full pool stops a worker quietly (exit 3).
- The pick lock. `next.sh` picks the item, claims the worktree and records the run under one
  lock (`<flow home>/pick.lock`), so runs started together never take the same item or
  worktree. A busy lock waits up to `FLOW_LOCK_WAIT` seconds (60), then exits 7; a lock whose
  holder died is taken over.
- `do` starts unattended runs from plain words: "start a one-off unattended run" runs the job in
  the background; "run a repeating unattended flow every 30 minutes" creates a scheduled task
  where the host has a tool for it, else gives the command and cadence for the owner's scheduler.
- `init` no longer writes `pool_max: 3` over a longer pool. When the repository already has more
  than three worktrees, `pool_max` is their count and `init` says that every one becomes a task
  slot.

## 1.1.0 (2026-10-11)

- `do`: the front door. A model-invoked skill that takes a plain sentence ("what is stuck?",
  "start the bots bug", "approve the plan for 312"), finds the item by its title, asks once before
  anything that runs agents or clears a gate, and follows the matching skill.
- `help`: a manual read from the installed plugin. `help` lists every skill with how to call it on
  Claude and Codex; `help <skill>` shows one; `help lines` and `help gates` show the steps per
  kind and size and what each stop asks of you. `scripts/help.sh` does the work.
- `auto_gates` in `.flow/config.yaml`: `plan-approval: S,M` lets the flow clear the plan-approval
  gate itself for those sizes (logged on the item and in `events.log`). Merge, interview,
  decomposition, feel-test, escalation and ambiguity, and a re-size gate, always wait. `init`
  flags any other name as a gap.
- `gate`: a skill to list the gates waiting on the owner and to answer one (`gate.sh clear`), so
  approving a plan, a spec or a task list is a command, not a script path.

## 1.0.0 (2026-10-11)

First stable release: the config keys and the hook contracts are kept from here on.


- `new`: a skill and `scripts/new.sh` create an epic, task or bug in the tracker the config names
  for the kind, with the item body shape, a size, blockers and a parent. Agents working a
  backlog use it for follow-ups; the planner creates sub-items through it.
- The pool grows on its own: a claim with no free worktree adds one while the pool is below
  `pool_max`, named after the last entry, appends it to `pool:` in `.flow/config.yaml`, copies
  the git-ignored files in `worktree_copy` from the main worktree and runs `worktree_setup`
  there. `steward.sh add [path]` does the same by hand; `steward.sh setup <path>` re-runs the
  copies and the commands. At `pool_max` the claim still fails with exit 3.
- `init` reports `Gaps` (an empty pool with `pool_max` 0, an empty base, an adapter that does
  not exist) and `init --check` counts them as drift; the config template carries `pool_max`,
  `worktree_copy` and `worktree_setup`, and the init skill asks the owner the config questions
  with a recommendation each.

## 0.2.0 (2026-10-11)

- The agents and the step skills read the testing guide at `.standards/testing-guide.md`
  (standards 0.2.0 moved it out of `docs/`).
- `init` writes `.flow/stamp`, refuses to replace a guarded copy edited by hand (`--force`), and
  a `SessionStart` hook asks for `init` when the stamp is behind the plugin. `init` writes only
  under `.flow/`, plus `.codex/rules/flow.rules`, `.codex/agents/` and the `.gitignore` block.
- Scheduled jobs: `comments`, `next` and `retro` under `.flow/jobs/`, with a lock and a log each.

## 0.1.0 (2026-10-10)

- First release of the rework: adapters, profiles, next/advance, the steward, gates, the board.
