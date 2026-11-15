# 1b. Architecture

- **A-01 Dependencies point inward; the core is framework-free.** [hard] Domain logic depends on nothing outside itself. Frameworks, engines and I/O sit at the edge and are chosen at the composition root. *Why:* a core that imports a framework cannot be tested, ported or replaced without it.
- **A-02 Pick the architecture for the problem.** [judgement] Clean Architecture is the default. For a new project or an exploration, consider DDD, a modular monolith, vertical slices, microservices, and patterns like event sourcing, CQRS, mediator or a message queue, when the problem fits them better. State the choice and why. *Why:* a default applied blindly is as bad as none.
- **A-03 Validate at boundaries, fail fast at startup.** [hard] Input is validated where it enters the system; bad configuration stops the process at startup, never later. Inside the boundary, values are trusted. *Why:* a bad value caught late is debugged far from its cause.
- **A-04 Logging goes through an injected abstraction.** [hard] No console writes in library code. Logs are structured. *Why:* library output must be routable, testable and silent when unwanted.
