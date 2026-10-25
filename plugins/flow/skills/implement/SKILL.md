---
name: implement
description: Implement an item's plan in its claimed worktree. One implementer per phase in fresh subagents; independent phases run in parallel in temporary worktrees and are rebased onto the task branch; the build stays green and each phase is committed. Use when the user asks to implement, build, ship or code an item, or when the next step of an item is implement.
disable-model-invocation: true
---

Implement one item. You orchestrate; the implementer agent writes the code. Plugin root `$P`:
the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path
`codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

## 1. Inputs

- The item id, its claimed worktree and branch (from `next.sh`, or `"$P/scripts/steward.sh" find <id>`;
  no claim means `"$P/scripts/steward.sh" claim <id>` first).
- `<reports>/plan.md` when the profile planned; else the item body is the plan (one phase).
- `<reports>/design.md`, the standards, `.standards/testing-guide.md`.

## 2. Phases

Read the phases and their `independent` flags. Walk them in order:

- A dependent phase runs in the claimed worktree: spawn `implementer` with a brief that names
  the item, the phase, the worktree, the reports path and the result file `<reports>/implement-<n>.json`.
- A run of consecutive independent phases runs in parallel: for each,
  `"$P/scripts/steward.sh" tmp add <id> phase-<n>` gives a temporary worktree on a branch from the
  task branch; spawn one `implementer` per phase there, at the same time. When all are done,
  rebase each phase branch onto the task branch in order (`git -C <worktree> rebase <task branch>`
  then fast-forward the task branch to it), resolving conflicts by the procedure in the
  implementer brief, and `tmp remove` each temporary worktree.
- A phase result of `fail` stops the walk: the remaining phases do not run. A `gate` stops it too.
- After the last phase, run the build once in the claimed worktree.

Never run two implementers in the same worktree. Never run a phase whose predecessor failed.

## 3. Bugfix and S tasks

One phase, one implementer, in the claimed worktree. For a bugfix, the brief names the repro
test from the `reproduce` step; the implementer runs it red, then green.

## 4. Tracker-tasks mode

When `plan.md` says the decomposition is tracker tasks, the children carry the work. Clearing
the decomposition gate splits the item (`steward.sh split`): its step becomes `split`, its
worktree goes back to the pool, and `next.sh` runs no step on it; it says to close it once every
child is closed. A child that needs the parent's commits names the parent's branch in its
`## Notes`: merge that branch into the child's branch first (never a rebase).

## 5. Finish

Write `<reports>/implement.json`: status `done` with the phases run and the commits, the union
of the phases' `touches`, and the size when an implementer changed the estimate; `fail` with
the failing phase's error text, cause and attempts; `gate` with the question. Report once.
