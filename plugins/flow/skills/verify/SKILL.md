---
name: verify
description: Verify an item in its worktree with the verifier agent: one run of build, format, tests, mutation and the project gates through verify.sh, one report (verify.json and verify.md), the acceptance lines walked, the feel-test flag. Also the epic closeout. Use when the user asks to verify an item or when the next step of an item is verify or closeout.
disable-model-invocation: true
---

Verify one item. Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on
Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Inputs**: the item, its claimed worktree (clean apart from `.flow/`), `.standards/config.json`
   (build, format, test, mutation), `.flow/config.yaml` (`gates`, `feel_test_paths`).
2. **Spawn `verifier`** with the step brief. The brief names `"$P/scripts/verify.sh" <item>`,
   which runs every check once and writes `<reports>/verify.json` and `verify.md`. The verifier
   adds the error text and cause for failed checks and walks the acceptance lines.
3. **Result**: `verify.json` is the step result. `pass` moves on; `fail` goes back to implement
   with the failing checks in the summary; three fails escalate. A pass with `feel_test: true`
   raises the feel-test gate after the step (the orchestrator does it from the report).
4. **Closeout** (epic): the verifier reads every sub-item, fails on any open one, runs
   `verify.sh` on the epic branch when there is one, walks the epic's acceptance lines, and
   closes the epic through the adapter only when every line is proven.
5. Report once: the status, the failing checks, where the report is.

The verifier never edits anything. A flaky check is a finding, not a retry. Never run the
checks yourself and skip the agent; the report must come from one run of `verify.sh`.
