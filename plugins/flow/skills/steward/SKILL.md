---
name: steward
description: Manage the worktree pool. Show the pool, claim a worktree for an item, reserve one for the owner's manual work, release one after merge, add a worktree to the pool, create or remove temporary worktrees for parallel phases, and resolve a merge or rebase conflict in a worktree. Use when the user asks about worktrees, wants one freed, claimed, reserved or reset, or a conflict resolved.
disable-model-invocation: true
---

Plugin root: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the
path `codex plugin list` prints for `flow`). Call it `$P`. The script is `"$P/scripts/steward.sh"`.

| Ask | Command |
|---|---|
| show the pool | `steward.sh pool` |
| claim for an item | `steward.sh claim <item> [--base <branch>]` prints the path |
| reserve one for manual work | `steward.sh reserve [<worktree>] [--name <who>]` takes a free worktree with no item under `<who>` (default: git `user.name`, else `$USER`) and prints its path; with none free it grows the pool or, at `pool_max`, exits 3, as `claim` does. `<worktree>` (a pool path or folder name, such as `app-wt-2`) takes that one when it has no claim, no reservation and a clean tree, and otherwise exits 3 with the reason: claimed by an item, reserved by someone, uncommitted changes, or not in the pool. `claim`, `sweep`, `health` and the `next` job never take or free it; `pool` and `board` show it reserved by that name |
| release after merge | `steward.sh release <item or path>`; add `--force` only when the owner says the unmerged branch may go. A reserved worktree is released by its path |
| add a worktree | `steward.sh add [path]`: adds it, appends it under `pool:` in `.flow/config.yaml`, copies the `worktree_copy` files and runs `worktree_setup`. A pool path missing on disk is recreated in place, its entry kept |
| set up a worktree again | `steward.sh setup <path or item>`: the copies and the setup commands, on demand |
| temporary worktree for a phase | `steward.sh tmp add <item> <phase>` from the task branch; `steward.sh tmp remove <path>` after the phase is rebased onto the task branch |
| where an item's reports are | `steward.sh reports <item>` prints the folder (and creates it): the claimed worktree's, else the one that already exists, else the main worktree's |
| check the pool: a run that died, a claim that holds nothing, branches out of step, gates waiting | `steward.sh health` clears a run record with no live process, releases an empty claim, resumes cut-off work (up to `jobs.health.max_resumes`, then an escalation gate), fast-forwards or pushes clean task branches, merges the base into one far behind it, hands a conflicting merge or a diverged branch to the `sync` step, reminds on old gates, clears a stale or wrong planned hold (`held_by`: the holder unreadable, idle with no worktree and no run, or its `changes` apart; a hold on itself; the newest in a cycle; a closed holder's hold is left for `next` to release with its merge note) with an `unheld` line in `events.log`, and names a valid hold waiting over a day once; `--dry-run` lists first. The scheduled `health` job runs it |
| see the sessions that hold worktrees, stale ones first | `steward.sh sessions [--stale]` lists each claude and codex session in the main worktree and the pool: pid, host, kind, worktree, the item its claim holds, busy or idle and for how long. One idle past `jobs.health.stale_session` (24h; with no status, alive that long) is marked STALE with its `kill <pid>`. A session in a claimed worktree holds that item's PR back from the comments job. The `health` job names each stale one once |
| end an item's run now | `steward.sh stop <item>` ends the process its run record names and every session under it, removes the record so `health` does not resume it, and keeps the claim, the worktree and its changes; it writes a `stopped` line to `events.log` and the item's `last_event`. Nothing running is said, exit 0; a malformed item exits 2. The next `next` run may continue the item from its step: pause `next` first to hold it |
| start a dead run again | `steward.sh resume <item> [--host H] [--wait]` clears a run record whose process is gone and starts the step again in the background, as `health` does: the same note in its brief, the same `jobs.health.max_resumes` count, then the escalation gate (exit 4). A live run (stop it first) or no record is refused, exit 1 |
| free the worktrees whose work landed | `steward.sh sweep` releases each claimed worktree whose item is closed or whose PR is merged: it clears the merge gate, closes an item the merge left open, and deletes a squash-merged branch still at the PR's head; `--dry-run` lists them first. The scheduled `next` and `health` jobs run it each time |
| clear old reports | `steward.sh prune` deletes `.flow/reports/<item>/` for closed items that no worktree claims, in the main and every pool worktree; `--dry-run` lists them first |

## Claude's own worktree features

`claude --worktree gh-310` (or `local-task-3`: the item id with `#`, `:` and `/` as dashes),
`EnterWorktree` and `isolation: worktree` all land in the pool through the plugin's
`WorktreeCreate` hook, which claims a free pool worktree for that item. Leaving the session
releases it through `WorktreeRemove` unless it holds uncommitted work; the folder stays in the
pool, on its idle branch at the base tip. A sub-agent's worktree (`isolation: worktree`) is kept
when the agent finishes and Claude Code runs no `WorktreeRemove` for it, so its claim stays until
`steward.sh release <path>` (or, for an item's claim, `sweep` or `health`) frees it. A pool path
removed from disk anyway (a session without the `WorktreeRemove` entry falls back to
`git worktree remove`) counts as free: the next claim recreates it on its idle branch, `health`
names it, and `steward.sh add <path>` recreates it now. Codex has no equivalent:
`codex exec -C <worktree>` after `steward.sh claim`.

## Rules

- **Never reset a worktree with uncommitted changes.** `release` exits 3 and says so. Tell the
  owner what is uncommitted (`git -C <path> status --short`) and stop. Do not stash, do not
  discard, do not force.
- Never create worktrees outside the pool except `tmp add`, and delete those after the phase.
- **The pool grows on its own.** A claim with no free worktree adds one while the pool is below
  `pool_max`, named after the last entry (`../app-wt-3` after `../app-wt-2`), appends it to
  `pool:` and runs the copies and the setup. `worktree_name: ../{repo}-wt-{n}` in the config names
  it instead (and `add` without a path): `{repo}` is the main worktree's folder, `{n}` the first
  number no pool entry and no folder uses. A `worktree_name` with no `{n}`, or with `{n}` only in a parent folder (every new worktree would share one idle branch), is refused. At `pool_max` the claim fails with exit 3: tell the
  owner, who raises `pool_max` or releases one. Never edit `pool:` by hand; `add` does it.
- A release of a closed item also deletes its reports in every worktree.
- A free worktree sits on its own idle branch at the base tip: `main-wt-2` for `../app-wt-2`
  (git checks a branch out in one worktree only, so each has its own). A release moves it back
  there and deletes the task branch when merged; an unmerged branch is kept and named in the
  output. The health job moves a free worktree left detached onto its idle branch.

## Resolving a merge or rebase conflict

1. See the state: `git status`, `git log --oneline -5` on both sides, the conflicting files.
2. Find the intent of each side: commit messages, the PR, the item. Read, do not guess.
3. Resolve each hunk keeping both intents where possible; where they clash, keep the one that
   matches the merge's stated goal and note the trade-off. Never invent behaviour. Never abort.
4. Run the project's checks (build, tests, format) and fix what the merge broke.
5. Finish: stage, commit; for a rebase, continue until every commit is replayed.
