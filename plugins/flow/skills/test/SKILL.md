---
name: test
description: Write the tests for an item from its acceptance lines, after implementation, with the test-writer agent in a fresh subagent; or, for a bug, write the one failing test that reproduces it. Use when the user asks for tests for an item, to reproduce a bug, or when the next step of an item is test or reproduce.
disable-model-invocation: true
---

Tests for one item. Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}`
on Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Inputs**: the item (acceptance lines), its claimed worktree, `<reports>/plan.md` (test
   seams) when present, `.standards/testing-guide.md`, the standards tests section.
2. **Spawn `test-writer`** with the step brief from `next.sh`, or one of the same shape. For
   step `reproduce` the brief says: one failing test that pins the bug, run red, committed. For
   step `test` the brief says: the behaviour list first, from the acceptance lines, written to
   `<reports>/tests.md` (that exact name) before any implementation file is opened; then the
   tests; then a run of the tests it wrote or changed, alone (the whole suite is verify's job,
   once, scoped to the change). A sandboxed Claude session commits only in the worktree it
   started in (the unattended run starts each step in the item's claimed worktree): started
   anywhere else, the writer's commit fails on `index.lock`, so name that in the report and
   stop rather than look for a way around it.
3. **Check the result file** `<reports>/test.json` (or `reproduce.json`): `done` with the count
   per level and the unpinned acceptance lines; `fail` when its tests do not run; `gate`
   when a seam is missing (the implementer fixes the interface, never the test writer).
   **For `reproduce`, review the diagnosis** before the fix is written: on `done`, spawn
   `epic-plan-reviewer` with the item, `<reports>/reproduce.json` and the committed test, asking
   for its diagnosis review. Write its report to `<reports>/diagnosis.md`. A Blocker (the test
   shows a lead, not the reported symptom; a named suspect neither measured nor ruled out; an
   acceptance line the fix path cannot meet) turns `reproduce.json` into `fail` with the first
   Blocker as the summary, and the fix loop sends the item back to reproduce. A Blocker only
   the owner can settle is `gate`, gate `ambiguity`. One pass; Risks and Gaps go to the
   implementer through `diagnosis.md`.
4. **End with one report** (W-07), in this shape: the `test-writer` subagent wrote the behaviour
   list from the acceptance lines to `<reports>/tests.md`, then the tests; the count per level;
   the result file (`<reports>/test.json`) and its status; the acceptance lines left unpinned;
   and any decision the owner must take. Nothing else first.
5. The test reviewer runs in the review step, not here.

Never let the test writer and the implementer be the same subagent. Never pass the
implementation diff in the brief; the writer reads the public interface itself, after the list.
