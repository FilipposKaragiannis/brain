---
name: steward
description: Manage the worktree pool. Show the pool, claim a worktree for an item, release one after merge, add a worktree to the pool, create or remove temporary worktrees for parallel phases, and resolve a merge or rebase conflict in a worktree. Use when the user asks about worktrees, wants one freed, claimed or reset, or a conflict resolved.
disable-model-invocation: true
---

Plugin root: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the
path `codex plugin list` prints for `flow`). Call it `$P`. The script is `"$P/scripts/steward.sh"`.

| Ask | Command |
|---|---|
| show the pool | `steward.sh pool` |
| claim for an item | `steward.sh claim <item> [--base <branch>]` prints the path |
| release after merge | `steward.sh release <item or path>`; add `--force` only when the owner says the unmerged branch may go |
| add a worktree | `steward.sh add [path]`: adds it, appends it under `pool:` in `.flow/config.yaml`, copies the `worktree_copy` files and runs `worktree_setup` |
| set up a worktree again | `steward.sh setup <path or item>`: the copies and the setup commands, on demand |
| temporary worktree for a phase | `steward.sh tmp add <item> <phase>` from the task branch; `steward.sh tmp remove <path>` after the phase is rebased onto the task branch |
| where an item's reports are | `steward.sh reports <item>` prints the folder (and creates it): the claimed worktree's, else the one that already exists, else the main worktree's |
| check the pool: a run that died, a claim that holds nothing, branches out of step, gates waiting | `steward.sh health` clears a run record with no live process, releases an empty claim, resumes cut-off work (up to `jobs.health.max_resumes`, then an escalation gate), fast-forwards or pushes clean task branches, merges the base into one far behind it, hands a conflicting merge or a diverged branch to the `sync` step, reminds on old gates; `--dry-run` lists first. The scheduled `health` job runs it |
| free the worktrees whose work landed | `steward.sh sweep` releases each claimed worktree whose item is closed or whose PR is merged: it clears the merge gate, closes an item the merge left open, and deletes a squash-merged branch still at the PR's head; `--dry-run` lists them first. The scheduled `next` and `health` jobs run it each time |
| clear old reports | `steward.sh prune` deletes `.flow/reports/<item>/` for closed items that no worktree claims, in the main and every pool worktree; `--dry-run` lists them first |

## Claude's own worktree features

`claude --worktree gh-310` (or `local-task-3`: the item id with `#`, `:` and `/` as dashes),
`EnterWorktree` and `isolation: worktree` all land in the pool through the plugin's
`WorktreeCreate` hook, which claims a free pool worktree for that item. Leaving the session
releases it through `WorktreeRemove` unless it holds uncommitted work. Codex has no equivalent:
`codex exec -C <worktree>` after `steward.sh claim`.

## Rules

- **Never reset a worktree with uncommitted changes.** `release` exits 3 and says so. Tell the
  owner what is uncommitted (`git -C <path> status --short`) and stop. Do not stash, do not
  discard, do not force.
- Never create worktrees outside the pool except `tmp add`, and delete those after the phase.
- **The pool grows on its own.** A claim with no free worktree adds one while the pool is below
  `pool_max`, named after the last entry (`../app-wt-3` after `../app-wt-2`), appends it to
  `pool:` and runs the copies and the setup. At `pool_max` the claim fails with exit 3: tell the
  owner, who raises `pool_max` or releases one. Never edit `pool:` by hand; `add` does it.
- A release of a closed item also deletes its reports in every worktree.
- A release leaves the worktree detached at the base branch with the task branch deleted when
  merged; an unmerged branch is kept and named in the output.

## Resolving a merge or rebase conflict

1. See the state: `git status`, `git log --oneline -5` on both sides, the conflicting files.
2. Find the intent of each side: commit messages, the PR, the item. Read, do not guess.
3. Resolve each hunk keeping both intents where possible; where they clash, keep the one that
   matches the merge's stated goal and note the trade-off. Never invent behaviour. Never abort.
4. Run the project's checks (build, tests, format) and fix what the merge broke.
5. Finish: stage, commit; for a rebase, continue until every commit is replayed.
