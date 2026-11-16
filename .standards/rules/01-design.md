# 1. Design

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
