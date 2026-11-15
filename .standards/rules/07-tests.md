# 5. Tests

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
