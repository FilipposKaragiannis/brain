# Agent notes

Project notes for agents, and the allowed list that N-05 in `docs/coding-standards.md` refers to.

## Testing the console

Test the console only on the demo project that `plugins/console/scripts/demo.sh` builds, never
on a real project. A trial console can make real changes in every project it watches, so never
point one at a real project, its worktrees or the owner's console settings.

- Run `plugins/console/scripts/demo.sh` from the repository root. It builds the demo in
  `$TMPDIR/brain-console-demo` and starts this checkout's console on it alone, on port 7478, in
  the foreground; Ctrl+C stops it. `--dir <folder>` and `--port <n>` move it.
- The demo has one item waiting at each gate (the feel-test one with the session that raised it),
  one ready item to run, a live run, a dead run, a session of yours, two job schedules with run
  history and a stopped host. Its agents are fake processes that end with the demo. Flow runs
  there call stub agents that spend no tokens; each call is a line in `agents.log` in the demo
  folder.
- The demo's home links your home, so a terminal it opens loads your shell setup, but never your
  `~/.claude`, `~/.codex`, console settings or launch agents. Its shell startup files then put the
  stub agents first on `PATH`, so a pane there runs no real agent.
- The token is in `<folder>/state/token`. Run the script again to reset the demo.
- Stop the demo console when you are done; leave no daemon running.

<!-- standards:begin v1.9.1 -->
# Coding standards (standards plugin v1.9.1)
Full text with reasons in `.standards/rules/`. Cite rules by id. Rules bind new and touched code
only; existing code is not refactored to meet a rule (U-05). A [judgement] breach is declared in the
commit message, the PR body and the review (U-02). Language conventions, one file per configured
language: `.standards/rules/shell.md` (Shell) and `.standards/rules/python.md` (Python). Project
rules outside this block win where they are stricter.

## Hard rules (a breach blocks)
- D-03 Compose, don't inherit.
- D-06 No compiler-flag branching in production code.
- D-07 No downcasting from interfaces or base types.
- D-08 Null-object over nullable defaults.
- D-09 Every parameter is explicit.
- D-10 No static mutable state.
- D-11 No service locator.
- D-12 No reflection in production code.
- D-13 No `dynamic`.
- A-01 Dependencies point inward; the core is framework-free.
- A-03 Validate at boundaries, fail fast at startup.
- A-04 Logging goes through an injected abstraction.
- P-02 Hot paths are declared, and zero-allocation there.
- S-03 No boolean state flags.
- S-04 Structs are data, not behaviour.
- S-05 Wrap primitives at boundaries.
- S-07 Immutable surface, owned storage.
- S-08 Return empty, never null, for collections.
- S-09 No `out` parameters.
- S-10 No tuples across non-private APIs.
- S-11 Time and randomness are injected.
- S-13 Exceptions are for broken invariants only.
- M-04 Single constructor per type.
- M-05 Async all the way.
- M-06 Every async method takes a cancellation token.
- M-08 No hidden side effects.
- N-04 Names state the role.
- N-05 No abbreviations.
- N-06 No magic numbers.
- T-01 A test fails only when functionality breaks.
- T-04 Test levels.
- T-07 No test without an assertion.
- T-08 No assertion on a double's calls.
- T-09 One behaviour per test.
- T-11 Names are behavioural sentences.
- C-01 No comments that explain code behaviour.
- C-03 No task, ticket, PR or spec identifiers in source.
- L-01 Code to green.
- L-02 Clean namespaces.
- L-03 `.editorconfig` is the single source of truth for formatting.
- W-01 Conventional commits, short bodies.
- W-02 One concern per PR.
- W-04 Minimal diff.
- W-05 Review severity.
- W-06 Learning loop.
- W-07 Reporting.

## Signals (split, or explain why not)
- M-01 Cyclomatic complexity above 5 or 6 per method is a signal.
- M-02 Nesting deeper than 2 inside a method is a signal.
- N-01 Files over 300 lines smell.
- N-02 More than 4 parameters smell.
- N-03 Long methods smell.
- T-05 Mutation score is a signal.
- T-06 Coverage is a signal.
- W-03 PR size is a signal.

## Code Review Rules
Review the touched code only. Cite every finding by rule id, file and line. A broken hard
rule is P0 and blocks. A crossed signal with no explanation is P1 and blocks. A judgement
disagreement is P2, a comment. Skip what the build and the hooks already enforce. Check the
spec separately from the standards and never merge the two lists. Tests follow T-01 to
T-13: a name of the shape Scenario_Outcome, a because string per assertion, one behaviour
per test, no assertion on a double's calls.
<!-- standards:end -->

## Test suites stay off the real checkout

A test touches only stubs, fakes and throwaway files under its suite's temp folder: never the
checkout it runs from, its worktrees, the owner's home or any real config. Every shell suite runs
in `tools/lib/sandbox.sh`, and a plugin app's `npm test` in `tools/lib/sandboxed.sh`: both clear
git's repository variables (`GIT_DIR` and the rest, which a git hook exports) and the git, Claude,
Codex and flow config pointers, give the run a throwaway home, and fail it when the checkout
changes. A new suite starts with the same two lines as `plugins/flow/tests/core-board.sh`;
`tools/lint.sh` checks every suite and app test script. A command gate in
`.standards/config.json` runs without git's repository variables too (`check-gates.sh`).

## Glossary

### Allowed abbreviations

- **pty**: pseudo-terminal; the node-pty library's term and the item's.
- **pid**: process id.
- **cols**: terminal columns; only at the wire and the node-pty boundary, daemon-owned names say
  `columns`.
- **cwd**: working folder; only at the node-pty and `child_process` boundary, daemon-owned names
  say `workingFolder`.
- **env**: environment variables; only at the node-pty boundary, daemon-owned names say
  `environment`.

### Verify report

- **verdict**: the report's first line, `Verdict: pass at <sha>` or `fail at <sha>`, then how
  many acceptance lines are proven live or by test.
- **proof**: what shows one acceptance line holds: a grade and a link to its evidence.
- **evidence**: a file a proof points to, such as a screenshot, a log or a test result file.
- **grade**: how an acceptance line was checked. **live**: run in the real app, with a captured
  file. **test**: a named automated test passed in this run, or in an earlier run verify reused:
  the same test command on the same files, and the report names that run. **build-only**: only
  that it builds. **blocked**: it could not be checked, with why.
- **proofs file**: `<reports>/proofs.json`, the verifier's grade for each acceptance line,
  written before the run and graded by verify at its end. A named proof overrides the
  verifier's grade for its line.
- **named proof**: a `Proof:` line under a numbered acceptance line in the `## Acceptance`
  section of the plan, `Proof: evidence/<name>.png by <capture>`; verify grades its line live
  from that file.
- **error**: what verify reports in place of a grade that does not hold, with why; counted as
  not proven and listed in the Not checked list. A named proof's error also fails verify.
- **Not checked list**: the report section, always present, of the acceptance lines graded
  build-only, blocked or error, each with its reason, and of a proofs file verify could not read.
