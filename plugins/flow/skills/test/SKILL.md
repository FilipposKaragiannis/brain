---
name: test
description: Write the tests for an item from its acceptance lines, after implementation, with the test-writer agent in a fresh subagent; or, for a bug, write the one failing test that reproduces it. Use when the user asks for tests for an item, to reproduce a bug, or when the next step of an item is test or reproduce.
disable-model-invocation: true
---

Tests for one item. Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}`
on Claude; on Codex the path `codex plugin list` prints for `flow`).

1. **Inputs**: the item (acceptance lines), its claimed worktree, `<reports>/plan.md` (test
   seams) when present, `.standards/testing-guide.md`, the standards tests section.
2. **Spawn `test-writer`** with the step brief from `next.sh`, or one of the same shape. For
   step `reproduce` the brief says: one failing test that pins the bug, run red, committed. For
   step `test` the brief says: the behaviour list first, from the acceptance lines, written to
   `<reports>/tests.md` (that exact name) before any implementation file is opened; then the
   tests; then the suite run.
3. **Check the result file** `<reports>/test.json` (or `reproduce.json`): `done` with the count
   per level and the unpinned acceptance lines; `fail` when the suite does not run; `gate`
   when a seam is missing (the implementer fixes the interface, never the test writer).
4. **Report once** (W-07), in this shape: the `test-writer` subagent wrote the behaviour
   list from the acceptance lines to `<reports>/tests.md`, then the tests; the count per level;
   the result file (`<reports>/test.json`) and its status; the acceptance lines left unpinned;
   and any decision the owner must take. Nothing else first.
5. The test reviewer runs in the review step, not here.

Never let the test writer and the implementer be the same subagent. Never pass the
implementation diff in the brief; the writer reads the public interface itself, after the list.
