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
| claim for an item | `steward.sh claim <item> [--base <branch>] [--branch <name>]` prints the path and records the base (`--base`, else the config `base`) and the task branch in `.flow/claim.json` and the item state (`base`, `branch`); `next.sh` passes the base it resolved for the item and the branch it picked. The task branch is the one the state records when the flow could have named it for the item (`flow/<slug>`, or its template with any title; never a base or the default branch), else an existing `flow/<slug>` (a claim made before the template), else the config `branch` template rendered (one, or one per kind; `{slug}`, `{key}`, `{kind}`, `{title}`; unset, `flow/{slug}`), so a title edit never renames it. A `--base` that is not a valid branch name, or a task branch git refuses, exits 2; a task branch another claim holds exits 4; both before anything is created |
| which item a branch belongs to | `steward.sh owner <branch>` prints the item whose pool claim holds it as its task branch, or nothing |
| reserve one for manual work | `steward.sh reserve [<worktree>] [--name <who>]` takes a free worktree with no item under `<who>` (default: git `user.name`, else `$USER`) and prints its path; with none free it grows the pool or, at `pool_max`, exits 3, as `claim` does. `<worktree>` (a pool path or folder name, such as `app-wt-2`) takes that one when it has no claim, no reservation and a clean tree, and otherwise exits 3 with the reason: claimed by an item, reserved by someone, uncommitted changes, or not in the pool. `claim`, `sweep`, `health` and the `next` job never take or free it; `pool` and `board` show it reserved by that name |
| release after merge | `steward.sh release <item or path>` (a detached verify run of the item ends first); add `--force` only when the owner says the unmerged branch may go. A reserved worktree is released by its path |
| add a worktree | `steward.sh add [path]`: adds it, appends it under `pool:` in `.flow/config.yaml`, copies the `worktree_copy` files and runs `worktree_setup`. A pool path missing on disk is recreated in place, its entry kept |
| set up a worktree again | `steward.sh setup <path or item>`: the copies and the setup commands, on demand |
| temporary worktree for a phase | `steward.sh tmp add <item> <phase>` on `<branch>-<phase>`, from the claim's task branch `<branch>`; `steward.sh tmp remove <path>` after the phase is rebased onto the task branch. With `worktree_create` set, that command makes the folder from `<branch>` and `tmp add` puts it on a new `<branch>-<phase>` at `<branch>`; with `worktree_remove` set, that command removes the folder (it must be gone after), then git's record of that worktree goes when the command left it, and its branch is deleted when it is the phase branch `tmp add` named for that folder: `<branch>-<phase>` of a pool claim's task branch, or `flow/<its folder under .flow/tmp>`. A failed command ends `tmp` with exit 1 after its output. `tmp add` refuses, exit 2, a phase with a character other than a letter, a digit, `.`, `_` or `-`, one that makes no valid branch name, and one whose branch or folder exists |
| where an item's reports are | `steward.sh reports <item>` prints the folder (and creates it): the claimed worktree's, else the one that already exists, else the main worktree's |
| check the pool: a run that died, a claim that holds nothing, branches out of step, gates waiting | `steward.sh health` clears a run record with no live process, releases an empty claim and a sub-agent's `adhoc:` claim whose session has ended, resumes cut-off work (up to `jobs.health.max_resumes`, then an escalation gate that says what the dead runs left: a result the last session wrote that the step did not advance on, the run's last log lines or that it logged none, and the log to read), fast-forwards or pushes clean task branches, discards a free worktree's changes that the base branch's history already holds (named one run first), merges the base into one far behind it, hands a conflicting merge or a diverged branch to the `sync` step, reminds on old gates, clears a stale or wrong planned hold (`held_by`: the holder unreadable, idle with no worktree and no run, or its `changes` apart; a hold on itself; the newest in a cycle; a closed holder's hold is left for `next` to release with its merge note) with an `unheld` line in `events.log`, and names a valid hold waiting over a day once; `--dry-run` lists first. The scheduled `health` job runs it |
| see the sessions that hold worktrees, stale ones first | `steward.sh sessions [--stale]` lists each claude and codex session in the main worktree and the pool: pid, host, kind, worktree, the item its claim holds, busy or idle and for how long. One idle past `jobs.health.stale_session` (24h; with no status, alive that long) is marked STALE with its `kill <pid>`. A session in a claimed worktree holds that item's PR back from the comments job. The `health` job names each stale one once |
| end an item's run now | `steward.sh stop <item>` ends the process its run record names, every session under it and its detached verify run (`verify.sh --start`), removes the record so `health` does not resume it, and keeps the claim, the worktree and its changes; it writes a `stopped` line to `events.log` and the item's `last_event`. Nothing running is said, exit 0; a verify run still going after its wait is said on stderr, exit 1, the rest stopped all the same; a malformed item exits 2. The next `next` run may continue the item from its step: pause `next` first to hold it |
| start a dead run again | `steward.sh resume <item> [--host H] [--wait]` clears a run record whose process is gone and starts the step again in the background, as `health` does: the same note in its brief, the same `jobs.health.max_resumes` count, then the escalation gate (exit 4). A live run (stop it first) or no record is refused, exit 1 |
| free the worktrees whose work landed | `steward.sh sweep` releases each claimed worktree whose item is closed or whose PR is merged: it clears the merge gate, drops any other gate (`gate.sh drop`: the record and the `gate:*` label go; an unanswered ambiguity or escalation question is quoted in its output and on the item), closes an item the merge left open, and deletes a squash-merged branch still at the PR's head; `--dry-run` lists them first. The scheduled `next` and `health` jobs run it each time |
| clear old reports | `steward.sh prune` deletes `.flow/reports/<item>/` for closed items that no worktree claims, in the main and every pool worktree; `--dry-run` lists them first |

## Claude's own worktree features

`claude --worktree gh-310` (or `local-task-3`: the item id with `#`, `:` and `/` as dashes),
`EnterWorktree` and `isolation: worktree` all land in the pool through the plugin's
`WorktreeCreate` hook, which claims a free pool worktree for that item. Leaving the session
releases it through `WorktreeRemove` unless it holds uncommitted work; the folder stays in the
pool, on its idle branch at the base tip. A sub-agent's worktree (`isolation: worktree`) is kept
when the agent finishes and Claude Code runs no `WorktreeRemove` for it. Its `adhoc:` claim holds
the pid of the session that ran the hook, and `health` releases it once that session has ended
(the branch kept when it holds commits); one with uncommitted changes is kept and named once, for
`steward.sh release <path>` after you commit or discard them. A pool path
removed from disk anyway (a session without the `WorktreeRemove` entry falls back to
`git worktree remove`) counts as free: the next claim recreates it on its idle branch, `health`
names it, and `steward.sh add <path>` recreates it now. Codex has no equivalent:
`codex exec -C <worktree>` after `steward.sh claim`.

## Rules

- **Never reset a worktree with uncommitted changes.** `release` exits 3 and says so. Tell the
  owner what is uncommitted (`git -C <path> status --short`) and stop. Do not stash, do not
  discard, do not force. The one exception is `health`'s own: in a free worktree whose every
  change the base branch's history already holds, it discards them on the run after it names
  them, while they stay unchanged and no session works there. It restores only the paths it
  checked and never touches `.flow/`.
- Never create worktrees outside the pool except `tmp add`, and delete those after the phase.
- A sandboxed Claude session commits and switches branches only in the worktree it started in:
  run from anywhere else, a claim, a release or a conflict's commit in a pool worktree fails on
  `index.lock`, so name that and stop rather than look for a way around it.
- **The pool grows on its own.** A claim with no free worktree adds one while the pool is below
  `pool_max`, named after the last entry (`../app-wt-3` after `../app-wt-2`), appends it to
  `pool:` and runs the copies and the setup. `worktree_name: ../{repo}-wt-{n}` in the config names
  it instead (and `add` without a path): `{repo}` is the main worktree's folder, `{n}` the first
  number no pool entry and no folder uses. A `worktree_name` with no `{n}`, or with `{n}` only in a parent folder (every new worktree would share one idle branch), is refused. At `pool_max` the claim fails with exit 3: tell the
  owner, who raises `pool_max` or releases one. Never edit `pool:` by hand; `add` does it.
- **A configured command makes the folder.** `worktree_create` in the config (a `sh` command;
  `{path}` the new worktree's absolute folder, `{base}` the ref it starts from, both written bare:
  `sh -c` gets them as `"$1"` and `"$2"`, so no value is read as shell; a command that passes
  `{path}` on to `ssh`, `eval` or `sh -c`, which parse it again, must quote it again there) replaces
  `git worktree add` for a grown, added or recreated pool worktree and for `tmp add`;
  `worktree_remove` (`{path}`) replaces `git worktree remove` for `tmp remove` only. Both run from
  the main worktree with their output on stderr; a pool worktree then goes onto its idle branch at
  the base tip, or stays as made for `health` to move it later. A command with no `{path}`, or
  with a placeholder inside quotes (a quoted `$(...)` too), after a backslash or anywhere inside
  backticks (write `$(...)` there), is refused, exit 2, and so is a create at a path where
  something already exists (`add` of the main or a pool worktree). `tmp remove` takes
  only a worktree git lists under `.flow/tmp`, never the main or a pool worktree, one whose
  `.git` is missing or broken, or a locked one, and nothing while `.flow/tmp` is a symlink: else exit 2 before anything
  runs. It counts as uncommitted a change in a submodule whatever `.gitmodules` says and an
  untracked file whatever `status.showUntrackedFiles` says, and
  refuses it, exit 3, as it does a worktree whose `git status` fails. A create that fails, or leaves no git worktree at `{path}`,
  adds no pool entry and says why after the command's output: the claim exits 1, not the
  `pool_max` exit 3, so tell the owner the command failed and name the folder it may have left
  (flow does not remove it). A slow create runs under the claim lock: a second claim that waits
  past `FLOW_LOCK_WAIT` (60 s) exits 75, the claim lock busy; try it again once the create ends.
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
