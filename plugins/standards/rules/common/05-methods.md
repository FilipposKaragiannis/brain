# 3. Methods and control flow

- **M-01 Cyclomatic complexity above 5 or 6 per method is a signal.** [signal] A method above it is doing too many things; split it. Each `switch` arm and each lambda body counts. *Why:* the number is not the goal, the split is.
- **M-02 Nesting deeper than 2 inside a method is a signal.** [signal] A lambda body and a `switch` arm each count as a level. *Why:* depth hides the happy path.
- **M-03 Favour early exits. Avoid `else`.** [judgement, strict] Guard first, then the main path. *Why:* one straight path reads in one pass.
- **M-04 Single constructor per type.** [hard] A private constructor plus a static factory counts as one. More than one build path is a conscious design decision, never a convenience for tests or debug code. *Why:* two paths that build the same object drift.
- **M-05 Async all the way.** [hard] Never block on a task (`.Result`, `.Wait()`, `.GetAwaiter().GetResult()`). Needing to is a design smell: make the caller async.
- **M-06 Every async method takes a cancellation token.** [hard] *Why:* work that cannot be cancelled leaks on shutdown and in tests.
- **M-07 Readability over cleverness.** [judgement] Named types and explicit steps beat terse chains and implicit conversions.
