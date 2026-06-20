---
description: Test-driven development with red-green-refactor loop. Use when user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first development.
---

# Test-Driven Development

> **Role in workstream.** This is the opt-in **red-green** variant. `ship` runs its default
> behavior-test workflow for most work and reaches for this only on logic-heavy / algorithmic
> work or a bug with a clear repro (or when you pass `--tdd`). The test-quality and design notes
> here ([tests.md](tests.md), [mocking.md](mocking.md), [interface-design.md](interface-design.md))
> are the **same bar** `ship`'s default uses — they are not TDD-specific. What this skill adds on
> top is only the loop mechanics: test-first, one test → one implementation, refactor on green.

## Philosophy

**Core principle**: Tests should verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't.

**Good tests** are integration-style: they exercise real code paths through public APIs. They describe _what_ the system does, not _how_ it does it. A good test reads like a specification - "user can checkout with valid cart" tells you exactly what capability exists. These tests survive refactors because they don't care about internal structure.

**Bad tests** are coupled to implementation. They mock internal collaborators, test private methods, or verify through external means (like querying a database directly instead of using the interface). The warning sign: your test breaks when you refactor, but behavior hasn't changed. If you rename an internal function and tests fail, those tests were testing implementation, not behavior.

**Testable by design, never by contamination**: Make code testable through its _public interface_ — inject dependencies at the boundaries, return values instead of mutating hidden state, keep the surface small (see [interface-design.md](interface-design.md) and [mocking.md](mocking.md)). The core implementation must **not** change for the sake of tests. No test-only code may exist in a core path: no `if (env == "Test")` / `#if DEBUG` test branches, no test-only methods, flags, or hooks, no widening a member's visibility (`public`/`internal`/`[InternalsVisibleTo]`) just so a test can reach it. If something is hard to test, fix the _interface_ — don't carve a seam into production code. Test-specific code in a core path is itself a defect.

See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines.

## Anti-Pattern: Horizontal Slices

**DO NOT write all tests first, then all implementation.** This is "horizontal slicing" - treating RED as "write all tests" and GREEN as "write all code."

This produces **crap tests**:

- Tests written in bulk test _imagined_ behavior, not _actual_ behavior
- You end up testing the _shape_ of things (data structures, function signatures) rather than user-facing behavior
- Tests become insensitive to real changes - they pass when behavior breaks, fail when behavior is fine
- You outrun your headlights, committing to test structure before understanding the implementation

**Correct approach**: Vertical slices via tracer bullets. One test → one implementation → repeat. Each test responds to what you learned from the previous cycle. Because you just wrote the code, you know exactly what behavior matters and how to verify it.

```
WRONG (horizontal):
  RED:   test1, test2, test3, test4, test5
  GREEN: impl1, impl2, impl3, impl4, impl5

RIGHT (vertical):
  RED→GREEN: test1→impl1
  RED→GREEN: test2→impl2
  RED→GREEN: test3→impl3
  ...
```

## Workflow

### 1. Planning

When exploring the codebase, use the project's domain glossary so that test names and interface vocabulary match the project's language, and respect ADRs in the area you're touching.

Before writing any code:

- [ ] Confirm with user what interface changes are needed
- [ ] Confirm with user which behaviors to test (prioritize)
- [ ] Identify opportunities for [deep modules](deep-modules.md) (small interface, deep implementation)
- [ ] Design interfaces for [testability](interface-design.md) — via dependency injection at the boundaries, never test-only hooks in core paths
- [ ] List the behaviors to test (not implementation steps)
- [ ] Get user approval on the plan

Ask: "What should the public interface look like? Which behaviors are most important to test?"

**You can't — and shouldn't — test everything.** Target the **meaningful** edge cases: boundary conditions, error and failure paths, and inputs where behavior genuinely changes — that's where bugs hide and where tests earn their value. Skip exhaustive permutations and anything that tests the _shape_ of the code rather than its behavior. Confirm the prioritized list with the user before writing code.

### 2. Tracer Bullet

Write ONE test that confirms ONE thing about the system:

```
RED:   Write test for first behavior → test fails
GREEN: Write minimal code to pass → test passes
```

This is your tracer bullet - proves the path works end-to-end.

### 3. Incremental Loop

For each remaining behavior:

```
RED:   Write next test → fails
GREEN: Minimal code to pass → passes
```

Rules:

- One test at a time
- Only enough code to pass current test
- Don't anticipate future tests
- Keep tests focused on observable behavior

### 4. Refactor

After all tests pass, look for [refactor candidates](refactoring.md):

- [ ] Extract duplication
- [ ] Deepen modules (move complexity behind simple interfaces)
- [ ] Apply SOLID principles where natural
- [ ] Consider what new code reveals about existing code
- [ ] Run tests after each refactor step

**Never refactor while RED.** Get to GREEN first.

## Checklist Per Cycle

```
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only
[ ] Test would survive internal refactor
[ ] Test covers a boundary/error path or a distinct behavior — not a trivial variant
[ ] Code is minimal for this test
[ ] No speculative features added
[ ] No test-only code in core paths (test branches, flags, hooks, or widened visibility)
```
