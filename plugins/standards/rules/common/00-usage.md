# 0. How these rules are used

- **U-01 Scope.** Language-neutral rules first; language specifics live in appendices (C# today). *Why:* the marketplace serves more than one language, so the philosophy must not be tied to C# syntax.
- **U-02 Breaking a [judgement] rule must be declared in three places:** the commit message, the PR body, and the review. *Why:* each is read at a different time by a different reader (log, reviewer, merge gate); one silent breach anywhere starts a review-and-fix loop.
- **U-03 A [hard] rule is a gate, not advice.** It is checked by a tool (analyzer, hook, CI) wherever one exists, and by the review otherwise. *Why:* rules that are only suggested are the ones agents skip.
- **U-04 A [signal] rule is a smell detector.** Numbers like complexity, nesting and size are guides that say "this is growing the wrong way", mostly for production code. Crossing one means the agent splits the code or states why not. *Why:* a hard numeric limit invites complexity added only to dodge the limit.
- **U-05 Rules bind new and touched code.** Existing code is not refactored to meet a rule unless the task touches it. No sweeping refactors to satisfy this file. *Why:* a rule that demands a mass rewrite gets ignored instead.
- **U-06 Each engine or framework gets a short exception list in the project rules** (static entry points, serialized fields, and the like). The philosophy itself has no engine exceptions. *Why:* the exception belongs where the engine is, not in the rule that applies everywhere.
- **U-07 Project concerns stay out of this file.** Determinism, fixed-point math, engine rules and domain vocabulary are project rules and live in the project repo. *Why:* this philosophy applies to every repo; a project rule does not.
