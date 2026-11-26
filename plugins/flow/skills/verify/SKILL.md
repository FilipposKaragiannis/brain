---
name: verify
description: Verify an item in its worktree with the verifier agent: one run of build, format, tests, mutation and the project gates through verify.sh, one report (verify.json and verify.md), a proof graded for each acceptance line, the feel-test flag. Also the epic closeout. Use when the user asks to verify an item or when the next step of an item is verify or closeout.
disable-model-invocation: true
---

Verify one item. Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on
Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Inputs**: the item, its claimed worktree (clean apart from `.flow/`), `.standards/config.json`
   (build, format, test, mutation), `.flow/config.yaml` (`gates`, `feel_test_paths`,
   `verify.limit`).
2. **Spawn `verifier`** with the step brief. Before the run the verifier writes
   `<reports>/proofs.json`, one grade per acceptance line (live, test, build-only or blocked)
   with its evidence file, test name or reason, for the commit it checks. The brief names
   `"$P/scripts/verify.sh" <item>`, which runs every check once and writes
   `<reports>/verify.json` and `verify.md`, each check with its seconds, and grades the proofs
   file into both: a proof that does not hold becomes an error, and every line graded
   build-only, blocked or error goes to the Not checked list with its reason. No proof changes
   the status. A build or test command with `paths` in `.standards/config.json` runs only
   when a changed file is under them, else it is a skipped check that says so. Use `{verify_base}`
   in a build or test command to pass it the merge-base commit. When the base cannot be resolved,
   the command receives `unavailable` and must run all checks: read any value that is not a full
   commit id that way, never as a ref, since a ref can take any name. The resolved command participates
   in test-pass reuse. A test command
   that passed on the same command and files is not run again: the check is a pass that names the run it
   came from (`--fresh` runs every command). A build always runs; its pass is kept so a push of
   the same inputs skips it (`scripts/build-passed.sh`). The verifier
   starts it with `--start`, detached, so it outlives any one shell call, and calls `--wait`
   again and again, each a single call under the host's limit, until it exits 0 (pass) or 1
   (fail); 3 is still running. The run stops at `verify.limit` in `.flow/config.yaml` (default
   `2h`; fit it to the slowest gate) and fails naming the check it was on. The verifier adds the
   error text and cause for failed checks and the lines graded error.
3. **Result**: `verify.json` is the step result. `pass` moves on; `fail` goes back to implement
   with the failing checks in the summary; three fails escalate. A run that was stopped (its
   limit, a signal, a run that died: `stopped` in the report) failed no check: the item stays
   at verify behind the escalation gate with no attempt counted, and the run after the clear
   reuses every test command that passed. A pass with `feel_test: true`
   raises the feel-test gate after the step (the orchestrator does it from the report).
4. **Closeout** (epic): the verifier reads every sub-item, fails on any open one, runs
   `verify.sh` on the epic branch when there is one, and walks the epic's acceptance lines. It
   never closes the epic: after a pass the orchestrator opens the PR from the epic branch into
   the epic's base (`scripts/epic-pr.sh`) and raises the merge gate, and the merge closes the
   epic; with nothing to merge the orchestrator closes it.
5. End with one report: the status, the failing checks, the line `N of M acceptance lines
   proven live or by test` from the report, the lines graded error, where the report is.

The verifier never edits anything. A flaky check is a finding, not a retry. Never run the
checks yourself and skip the agent; the report must come from one run of `verify.sh`. A wait is
not a rerun, and a second `--start` while the run goes starts nothing.
