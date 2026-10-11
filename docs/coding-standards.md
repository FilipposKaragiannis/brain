# Coding standards

Non-exhaustive. Each rule is marked **[hard]** (can be checked by a tool or a reviewer with a yes/no answer and blocks when broken), **[signal]** (a tool reports it; the agent refactors or explains, it never blocks) or **[judgement]** (needs reasoning; agents must explain when they break it).

## 0. How these rules are used

- **U-01 Scope.** Language-neutral rules first; language specifics live in appendices (C# today). *Why:* the marketplace serves more than one language, so the philosophy must not be tied to C# syntax.
- **U-02 Breaking a [judgement] rule must be declared in three places:** the commit message, the PR body, and the review. *Why:* each is read at a different time by a different reader (log, reviewer, merge gate); one silent breach anywhere starts a review-and-fix loop.
- **U-03 A [hard] rule is a gate, not advice.** It is checked by a tool (analyzer, hook, CI) wherever one exists, and by the review otherwise. *Why:* rules that are only suggested are the ones agents skip.
- **U-04 A [signal] rule is a smell detector.** Numbers like complexity, nesting and size are guides that say "this is growing the wrong way", mostly for production code. Crossing one means the agent splits the code or states why not. *Why:* a hard numeric limit invites complexity added only to dodge the limit.
- **U-05 Rules bind new and touched code.** Existing code is not refactored to meet a rule unless the task touches it. No sweeping refactors to satisfy this file. *Why:* a rule that demands a mass rewrite gets ignored instead.
- **U-06 Each engine or framework gets a short exception list in the project rules** (static entry points, serialized fields, and the like). The philosophy itself has no engine exceptions. *Why:* the exception belongs where the engine is, not in the rule that applies everywhere.
- **U-07 Project concerns stay out of this file.** Determinism, fixed-point math, engine rules and domain vocabulary are project rules and live in the project repo. *Why:* this philosophy applies to every repo; a project rule does not.

## 1. Design

- **D-01 Deep modules, narrow surface.** [judgement] A type hides its complexity behind a small, clearly named API. Callers never need to know the internals. Prefer a few deep types over many shallow pass-throughs. Name types and public methods for *what they do*, not how.
- **D-02 One responsibility.** [judgement] A type or method has one reason to change. Don't add a second concern to a type because it is nearby.
- **D-03 Compose, don't inherit.** [hard] Build behaviour from small, focused parts injected through the constructor. Never extend a class to share logic, and never rely on virtual methods to vary behaviour. Closed record families (a base record with sealed variants, matched exhaustively) are welcome and preferred. No deep class trees. *Why:* inheritance of logic couples the child to the parent's internals; a record family is data with no logic to inherit.
- **D-04 Abstractions must earn their place.** [judgement] Add an interface or wrapper only when it isolates a boundary, enables testing, or removes a coupling. Never speculatively. Wait for the second consumer (YAGNI).
- **D-05 No unnecessary dependencies.** [judgement] Don't add a package for what a few lines of owned code can do. The core stays lean and portable.
- **D-06 No compiler-flag branching in production code.** [hard] Avoid `#if` blocks (e.g. `#if UNITY_EDITOR`) inside logic. Branch at the composition root instead, by choosing a different implementation of an abstraction.
- **D-07 No downcasting from interfaces or base types.** [hard] Don't use `is`, `as`, or explicit casts to get a concrete type or a second interface out of a reference (a class implementing `A` and `B` must never be reached as `B` through an `A` reference). Exhaustive matching over a closed record family is not downcasting and is allowed. *Why:* inferring one abstraction from another means the caller depends on a fact the interface never promised.
- **D-08 Null-object over nullable defaults.** [hard] Provide a null-object implementation of an interface instead of a nullable parameter with a default value. Defaults hide intent.
- **D-09 Every parameter is explicit.** [hard] No optional parameters (`T? x = null`, `int x = 0`). A value that is null is passed as `null`, never omitted. `T?` as a parameter or field type is fine. *Why:* the call site must show every input the callee depends on; an omitted argument hides a dependency.
- **D-10 No static mutable state.** [hard] *Why:* hidden global state breaks testability, determinism and parallel runs.
- **D-11 No service locator.** [hard] Dependencies arrive through the constructor. *Why:* a locator hides what a type needs.
- **D-12 No reflection in production code.** [hard] *Why:* it bypasses the type system and breaks AOT and trimming on console and mobile.
- **D-13 No `dynamic`.** [hard] *Why:* same as reflection, plus it hides errors until runtime.

## 1b. Architecture

- **A-01 Dependencies point inward; the core is framework-free.** [hard] Domain logic depends on nothing outside itself. Frameworks, engines and I/O sit at the edge and are chosen at the composition root. *Why:* a core that imports a framework cannot be tested, ported or replaced without it.
- **A-02 Pick the architecture for the problem.** [judgement] Clean Architecture is the default. For a new project or an exploration, consider DDD, a modular monolith, vertical slices, microservices, and patterns like event sourcing, CQRS, mediator or a message queue, when the problem fits them better. State the choice and why. *Why:* a default applied blindly is as bad as none.
- **A-03 Validate at boundaries, fail fast at startup.** [hard] Input is validated where it enters the system; bad configuration stops the process at startup, never later. Inside the boundary, values are trusted. *Why:* a bad value caught late is debugged far from its cause.
- **A-04 Logging goes through an injected abstraction.** [hard] No console writes in library code. Logs are structured. *Why:* library output must be routable, testable and silent when unwanted.

## 1c. Performance

- **P-01 Measure before optimising.** [judgement] *Why:* a guess at the hot spot is usually wrong.
- **P-02 Hot paths are declared, and zero-allocation there.** [hard] A project names its hot paths (by folder or marker). Inside them no allocation per step, no LINQ, no interface enumeration, no closures. Outside them readability wins. *Why:* the rule is strict only where it pays; everywhere else it would cost clarity for nothing.

## 2. State and data

- **S-01 Minimise stored state.** [judgement] Keep a field only when its value must survive across calls *and* can't be cheaply recomputed. Otherwise use a local, a parameter, or a derived value. Don't create a field to cache something you can read from an existing reference (e.g. use `settings.AnimationSeconds` at the call site, not a copied `animationSeconds` field).
- **S-02 Pure functions and immutability first.** [judgement] Prefer pure functions and immutable data. Avoid state spread across several fields that must stay in sync; model it as one value or one type.
- **S-03 No boolean state flags.** [hard] Absence is `T?`; variants are an enum or a closed family. Never a `_hasX`/`_isY` field beside a value. *Why:* a parallel flag is a second variable that can contradict the first.
- **S-04 Structs are data, not behaviour.** [hard] No mutating methods and no methods with logic on structs. Pure operators, math and `With`-style copies are fine. Prefer `readonly record struct` / `readonly struct`. *Why:* a struct that changes itself is copied silently and the change is lost.
- **S-05 Wrap primitives at boundaries.** [hard] Every non-private property or parameter carries its meaning in a type: `readonly struct Speed(float value)`, not `float Speed`. Indices and counts stay bare only where they are the collection's own API. *Why:* a bare primitive can be passed where another is meant, and the compiler says nothing.
- **S-06 Collection operations get their own type.** [judgement] When the same operation on a collection appears more than once, move it into a dedicated type that owns and reuses that logic.
- **S-07 Immutable surface, owned storage.** [hard] One type owns its mutable storage (an array, a buffer) and exposes it only as a read-only view (`ReadOnlySpan<T>`, a read-only value). No type exposes a mutable collection. Allocating copy-on-write structures are for cold paths only. *Why:* immutability and zero allocation are both wanted; this is the one shape that gives both.
- **S-08 Return empty, never null, for collections.** [hard] *Why:* every caller would otherwise need a null check that is easy to forget.
- **S-09 No `out` parameters.** [hard] Return a value, a `T?`, or a small record. *Why:* `out` splits one result across two places.
- **S-10 No tuples across non-private APIs.** [hard] Name the shape as a record. *Why:* `Item1`/`Item2` carries no meaning.
- **S-11 Time and randomness are injected.** [hard] A clock and a seed arrive through the constructor; nothing reads the system clock or an unseeded random source. *Why:* without this nothing is reproducible, and determinism is impossible.
- **S-12 Errors and alternatives as values.** [judgement] Prefer result/option types over exceptions for expected failure paths. Result and option types are hand-rolled, not a package.
- **S-13 Exceptions are for broken invariants only.** [hard] An exception means a programmer error or an impossible state. Never use one for control flow or an expected outcome (not found, invalid input, timeout). *Why:* an expected outcome is part of the API and must show in the return type.
- **S-14 Close what should not be extended.** [judgement] Where extension is not expected, use a closed family (sealed variants, exhaustive match). `switch` is fine; a throwing `default` is acceptable where the compiler cannot prove the family closed. *Why:* an open shape invites a new case the matches never handle.

## 3. Methods and control flow

- **M-01 Cyclomatic complexity above 5 or 6 per method is a signal.** [signal] A method above it is doing too many things; split it. Each `switch` arm and each lambda body counts. *Why:* the number is not the goal, the split is.
- **M-02 Nesting deeper than 2 inside a method is a signal.** [signal] A lambda body and a `switch` arm each count as a level. *Why:* depth hides the happy path.
- **M-03 Favour early exits. Avoid `else`.** [judgement, strict] Guard first, then the main path. *Why:* one straight path reads in one pass.
- **M-04 Single constructor per type.** [hard] A private constructor plus a static factory counts as one. More than one build path is a conscious design decision, never a convenience for tests or debug code. *Why:* two paths that build the same object drift.
- **M-05 Async all the way.** [hard] Never block on a task (`.Result`, `.Wait()`, `.GetAwaiter().GetResult()`). Needing to is a design smell: make the caller async.
- **M-06 Every async method takes a cancellation token.** [hard] *Why:* work that cannot be cancelled leaks on shutdown and in tests.
- **M-07 Readability over cleverness.** [judgement] Named types and explicit steps beat terse chains and implicit conversions.

## 4. Files and naming

- **N-01 Files over 300 lines smell.** [signal] Explore decomposition.
- **N-02 More than 4 parameters smell.** [signal] Group the inputs in a record. *Why:* long parameter lists hide a missing type.
- **N-03 Long methods smell.** [signal] A method that needs scrolling is doing several things. *Why:* same signal as complexity, read from a different angle.
- **N-04 Names state the role.** [hard] A name says what the value is in domain terms (`ballSweep`, `resolvedState`), never `tmp`, `data`, `flag`, `mgr`, `helper`, `util`. If a name needs a comment to be understood, rename until it does not. *Why:* the code carries no explanatory comments, so the name is the documentation.
- **N-05 No abbreviations.** [hard] Names are spelt in full, units included (`degreesPerSecond`, not `degPerSec`). An acronym is allowed only after review, only when it shrinks a very long name, and only once it is on the project's allowed list. *Why:* an abbreviation saves the writer seconds and costs every reader a guess.
- **N-06 No magic numbers.** [hard] Every literal with meaning gets a named constant or a setting. *Why:* a bare `0.35` says nothing about what it tunes.
- **N-07 Say it once (DRY).** [judgement] When the same logic appears twice, extract a shared pure helper.
- **N-08 Keep it simple (KISS).** [judgement]

## 5. Tests

- **T-01 A test fails only when functionality breaks.** [hard] Every test must fail when the behaviour it names is broken, and pass regardless of how that behaviour is written. A test that asserts a constant equals its literal, reads a private field, or pins exact output text tests a definition, not behaviour, and is noise. *Why:* a test that cannot fail for a real reason costs upkeep and proves nothing.
- **T-02 Tests assert behaviour and edge cases, with meaningful values.** [judgement] Core functionality first, then the boundaries where behaviour changes. Values are chosen so a wrong answer is visibly wrong, not round numbers that pass by accident.
- **T-03 Tests are written after the implementation, from the spec.** [judgement] Red-green-refactor is not the workflow: an agent must not write code to satisfy a test it wrote. It implements the behaviour, then writes the tests that would catch the behaviour breaking. *Why:* test-first with an agent produces code shaped to pass, not code shaped to be right.
- **T-04 Test levels.** [hard] Unit tests on every change, kept reasonable (real logic, not every method). An integration test where a boundary is crossed. A regression test on every bug fix, named after the bug. Mutation testing, when the project turns it on (`mutation` in `.standards/config.json`; empty is off), runs in CI, scoped to the change on a PR and in full on a schedule, because it is slow. *Why:* each level catches a class of fault the others miss.
- **T-05 Mutation score is a signal.** [signal] Reported on every PR, never a merge gate. *Why:* a surviving mutant is a test to sharpen, not a reason to block.
- **T-06 Coverage is a signal.** [signal] *Why:* a coverage number is easy to game and says nothing about assertion quality.
- **T-07 No test without an assertion.** [hard]
- **T-08 No assertion on a double's calls.** [hard] Assert the outcome, not that a method was called. *Why:* call assertions pin the implementation.
- **T-09 One behaviour per test.** [hard] One reason to fail per test. *Why:* a test that fails for three reasons tells you nothing about which.
- **T-10 Doubles.** [judgement] A mocking framework is allowed when a unit test needs it. Never duplicate a type or hand-roll a stub with no purpose beyond avoiding a mock. Never widen production code for a test.
- **T-11 Names are behavioural sentences.** [hard] `ScenarioOrInput_ExpectedOutcome`. Each assertion states its invariant in a because-string. *Why:* the name is the spec, so test bodies need no comments.
- **T-12 Testability through real seams.** [judgement] Make code testable through constructor-injected interfaces and pure functions. Never expose internals, add test hooks, or add constructors for tests. Hard-to-test code is a design signal: fix the seam.
- **T-13 Test enforcement belongs to the plugin.** The review and verify steps check these rules; a project adds only its own fixtures and runners. *Why:* the rules are the same in every repo.

## 6. Comments and documentation

- **C-01 No comments that explain code behaviour.** [hard] Names, small types and explicit steps carry the meaning. The one exception is math, physics or a rigid complex computation, where a short comment explains *why* the formula has its shape. *Why:* a comment that restates the code rots and lies.
- **C-02 API documentation is welcome on public APIs and system boundaries.** [judgement] Doc comments (`///` in C#) describe what a public type or boundary promises. They sit directly above a `public` declaration, or above any declaration inside an `interface` or `enum`, whose members carry no modifier (attribute lines in between are fine). Internals carry no docs; a doc elsewhere needs `[allow-docs]` in the commit message. The hook reads the container kinds from `comments.doc_inside` in `.standards/config.json`; `interface` and `enum` when the key is absent, `[]` turns it off. *Why:* a boundary is read by people who cannot see the code behind it.
- **C-03 No task, ticket, PR or spec identifiers in source.** [hard] That context lives in the work item. *Why:* the source outlives the tracker.

## 7. Linting and formatting

- **L-01 Code to green.** [hard] Zero warnings in any file. Warnings are build errors. Style and usage analyzers run in the build, so unused usings and unused members fail it. Editor-only inspections are added as a tool only where the build cannot catch the rule. *Why:* a yellow file is a review-and-fix loop waiting to happen; keep the infrastructure simple.
- **L-02 Clean namespaces.** [hard] No unused usings, usings sorted with the platform namespace first, no global usings, namespace equals folder path. *Why:* a file's header tells the reader exactly what it depends on.
- **L-03 `.editorconfig` is the single source of truth for formatting.** [hard] One per repo, changed only by the owner. The formatter runs in a pre-commit hook and CI verifies no changes. Editor-specific keys are extras, never the rule. *Why:* a rule that lives in one person's editor is invisible to agents and CI.

## 8. Commits, PRs and behaviour

- **W-01 Conventional commits, short bodies.** [hard] `type(scope): summary`, then a body of a few short lines that says what changed and why. No essays. *Why:* a long commit message is not read.
- **W-02 One concern per PR.** [hard] *Why:* a mixed PR cannot be reviewed or reverted cleanly.
- **W-03 PR size is a signal.** [signal] Around 400 changed lines means it should have been two PRs.
- **W-04 Minimal diff.** [hard] Change only what the task needs. No renames or refactors outside the agreed scope, no error handling for impossible cases. A second post-hoc refactor of the same code means the design is wrong: stop and replan. *Why:* every extra line is review cost and risk with no value to the task.
- **W-05 Review severity.** [hard] A broken hard rule blocks. A crossed signal with no explanation blocks. A judgement disagreement is a comment. Specialised review agents enforce this. *Why:* the reviewer must never have to decide how serious a finding is.
- **W-06 Learning loop.** [hard] A decision goes to an ADR, a new word to the glossary, a new rule to this file. Only the owner approves a change to this file, and a rule meant to apply everywhere also changes the plugin that enforces it. *Why:* a rule that lives only in one project's docs is not a rule.
- **W-07 Reporting.** [hard] An agent reports once, at the end of the work, never phase by phase unless a phase needs approval. The report says what changed, what the owner must test by hand, and what is next. Nothing else: no compilation logs, no narration. On a failure the order is the error text, then the cause, then the fix attempted. *Why:* the owner reads one message and decides; everything else is noise that costs tokens and attention.
- **W-08 Ambiguity: ask, unless current practice already answers it.** [judgement] When a spec is ambiguous and the codebase shows an established way, follow it and state the assumption. Otherwise stop and ask. *Why:* a wrong guess costs more than a question; a question about something the code already answers costs the owner's time.

## Appendix A. C#

- **CS-01** `sealed` and `internal` by default. `public` only across an assembly boundary.
- **CS-02** `var` preferred. Private fields `_camelCase`, constants `PascalCase`, interfaces `IPascalCase`.
- **CS-03** Nullable reference types enabled everywhere.
- **CS-04** Expression bodies only for single-line returns; everything else is a block body.
- **CS-05** Max line length 200.
- **CS-06** No `#region`.
- **CS-07** `readonly record struct` / `readonly struct` for values, `sealed record` for immutable data and configuration, `with` for copies.
- **CS-08** Hot-path values are `readonly struct` passed `in`; storage is `T[]`, surface is `ReadOnlySpan<T>`, iteration is an index `for`.
- **CS-09** Never `.Result`, `.Wait()`, `.GetAwaiter().GetResult()`.
- **CS-10** Tests: NUnit or xUnit with FluentAssertions; because-strings on every assertion; `[TestCase]` for genuine data variants.
- **CS-11** Doc comments are `///`, on public APIs and boundaries only: above `public` declarations and on `interface` and `enum` members.
- **CS-12** `.editorconfig` severities drive the Roslyn style and usage analyzers; `dotnet format` is the formatter.
