# Coding standards (standards plugin v1.0.0)
Full text with reasons in `.standards/rules/`. Cite rules by id. Rules bind new and touched
code only; existing code is not refactored to meet a rule (U-05). A [judgement] breach is
declared in the commit message, the PR body and the review (U-02). Language conventions:
`.standards/rules/csharp.md`. Project rules outside this block win where they are stricter.

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
