# flow

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
