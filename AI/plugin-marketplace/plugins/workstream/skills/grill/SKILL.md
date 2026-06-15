---
name: grill
description: Relentlessly interview the user about a plan until shared understanding is reached — challenging it against the codebase and the project glossary, sharpening terminology, and recording durable decisions (glossary terms, ADRs) inline. Use to stress-test a plan before writing a spec. Hands off to to-epic.
---

# workstream: grill

Interview the user relentlessly about every aspect of this plan until you reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one at a time. For each question, provide your recommended answer.

**Ask one question at a time. Wait for the answer before asking the next.** If a question can be answered by reading the codebase, read the codebase instead of asking.

This skill OWNS all interrogation. It produces no spec — its output is a converged conversation plus durable repo knowledge (glossary, ADRs). `to-epic` serializes that understanding later; it does not re-ask.

## During the session

### Challenge against the glossary

Read the `## Glossary` section in `CLAUDE.md` (or `AGENTS.md`). When the user uses a term that conflicts with it, call it out immediately: "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses a vague or overloaded term, propose a precise canonical one: "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Probe with concrete scenarios

When domain relationships come up, stress-test them with specific edge-case scenarios that force the user to be precise about the boundaries between concepts.

### Cross-reference the code

When the user states how something works, check whether the code agrees. Surface contradictions: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Record the glossary inline

When a term is resolved, update the `## Glossary` section in `CLAUDE.md` right there — don't batch them up. Format:

```
**Order**: A confirmed request from a Customer to purchase goods.
_Avoid_: purchase, transaction
```

Keep it tight (1-2 sentences) and totally free of implementation detail. It is a glossary, not a spec or a scratchpad.

### Offer ADRs sparingly

Offer to record an ADR only when ALL THREE are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful.
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **A real trade-off** — genuine alternatives existed and you picked one for specific reasons.

If any is missing, skip it. When warranted, write `docs/adr/NNNN-slug.md` (sequential number — scan `docs/adr/` for the highest and increment; create the directory lazily). Body is 1-3 sentences: context, decision, why. Add optional `Status` frontmatter or `Consequences`/`Considered Options` sections only when they add genuine value — most ADRs won't need them.

## Wrapping up

Continue until the decision tree has no unresolved branches, or the user signals they're done ("that's it", "write it up", "let's move on"). Then:

1. Present a short recap of what was decided, plus any glossary terms or ADRs written.
2. Ask the user to confirm it's accurate or flag corrections.
3. On confirmation, tell the user: "Understanding locked. Run `to-epic` to publish this as an epic issue."
