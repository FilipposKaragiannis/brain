# flow

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
