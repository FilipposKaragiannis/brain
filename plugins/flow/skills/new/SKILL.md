---
name: new
description: Create an item in the project's tracker (an epic, a task or a bug) with a title, a body in the item shape, a size, blockers and a parent. Use when the user asks to file, add, create or log a piece of work, or when an agent working a backlog needs a follow-up item for something out of its scope.
---

Create one item. The script picks the tracker from `.flow/config.yaml` (`adapters.<kind>`, else
`adapters.default`) and prints the id (`gh#310`, `local:task/3`).

Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex
the path `codex plugin list` prints for `flow`).

## Steps

1. **Check it does not exist.** `"$P/adapters/<adapter>/list.sh"` lists the open items; a title
   that already covers the ask means a comment on that item, not a new one. Say which.
2. **Choose the kind.** `bug`: a behaviour that is wrong today, with a way to see it. `epic`: an
   outcome that needs several PRs; it gets no size and the `grill` step writes its spec.
   `task`: everything else. The size is `S` (one sitting, no design), `M` (a design and a plan)
   or `L` (a plan with phases); leave it out when the flow should size it.
3. **Write the body** in the item shape, under 150 words. For an epic, the first two sections only.
   ```markdown
   ## Problem
   What is wrong or missing today, from the user's side. One paragraph.

   ## Outcome
   What is true once this is done. One paragraph.

   ## Acceptance
   - [ ] binary, testable lines; one per behaviour

   ## Out of scope
   - what this item does not do (empty is fine)

   ## Notes
   Links, the originating discussion, the file or area if known.
   ```
   For a bug, `## Problem` holds the steps to see it and what happens instead.
4. **Create it:**
   ```
   "$P/scripts/new.sh" <kind> "<title>" [--size S|M|L] [--blocked-by gh#a,gh#b] [--parent gh#N] --body-file <file>
   ```
   Write the body to a file first (`--body-file -` reads stdin). `--parent` makes a sub-item of
   an epic; `--blocked-by` records the dependency edges. The title is a sentence of under ten
   words that names the outcome, not the work ("Bots never stall", not "Fix bot stalling").
5. **Report** the id and the title in one line. Nothing else changes: no claim, no worktree, no
   plan. `flow:next` picks the item up when it is ready.

## Agents creating items

An agent that finds work outside its item (a bug it cannot fix in scope, a follow-up the plan
named) creates it here with `--blocked-by` or `--parent` set so the board shows the edge, and
names the originating item in `## Notes`. It never creates an item to widen its own scope.

## Never

- Never create an item without an `## Acceptance` section, except an epic.
- Never create a duplicate: list first.
