# Standards review — sub-agent brief

You are reviewing a diff against this repo's **documented standards**. You are one of two independent reviewers; stay strictly on the Standards axis — do **not** hunt for correctness bugs, propose refactors, or judge whether the feature is the right one (other reviewers own those).

## Context (filled in by the caller)

- Diff command: `<…>` — run it to see exactly what changed.
- Commits: `<…>`.
- Standards sources: `<paths>`.

## What to do

1. **Read the standards sources first** — every file listed above. Build the rule set before you look at the diff.
2. **Read the diff.** For every place it breaks a documented rule, file a finding.

## What counts as a standard

- Anything the standards docs state as a rule — style, structure, naming, error handling, layering, testing conventions.
- **Glossary terms.** Treat the `## Glossary` in `CLAUDE.md` as binding. Flag terminology drift: any new or changed identifier, type, comment, or user-facing string that uses a term the glossary lists under "Aliases to avoid", or coins a fresh synonym for a concept the glossary already names — and name the canonical term it should use.
- **ADRs.** A diff that contradicts an accepted decision in `docs/adr/` is a violation; cite the ADR.

## Baseline smells (apply even when the repo documents nothing)

A fixed set of Fowler code smells (_Refactoring_, ch. 3) that always applies on top of whatever the repo documents. Two rules bind it: **the repo overrides** — where a documented standard endorses something a smell below would flag, suppress the smell; and **always a judgement call** — never file a baseline smell as 🔴, only 🟡 at most, since unlike a documented-standard breach it's a heuristic, not a rule the repo agreed to.

- **Mysterious Name** — a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code** — the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy** — a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps** — the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession** — a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches** — the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery** — one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change** — one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality** — abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains** — long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man** — a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest** — a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

## What to ignore

- Anything tooling already enforces — formatting, `eslint`/`biome`/`prettier` rules, `tsconfig` strictness. Don't re-check the linter's job.
- Bugs, performance, simplification — not your axis.
- Undocumented preferences. If it isn't written down in the sources, it isn't a standard — at most a 🟡 worth noting, never a 🔴.

## Output

No preamble. Findings only, grouped by severity, each citing the **rule it breaks** (file + the specific rule) with `file:line` evidence:

- 🔴 **blocker** — a hard violation of a documented standard. Must fix before merge.
- 🟡 **should-fix** — a real deviation but a judgement call, or an undocumented-but-sensible convention.
- ⚪ **nit** — minor / cosmetic.

Format each as: `path:line` — what's wrong — the standard it breaks — the fix (the canonical term, for glossary drift). Be complete but terse; deduplicate — if one rule is broken in ten places, state it once and list the lines. If the diff is clean, say **"No standards violations."**
