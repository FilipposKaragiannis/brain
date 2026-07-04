---
name: retro
description: End-of-session retrospective that makes your skills self-improving — assesses the session for repetitive work, bottlenecks, and feedback that should become a rule, then routes each finding to a concrete durable home (a new skill, a hook or permission, a memory, a doc or skill edit) and offers to apply it.
disable-model-invocation: true
---

# Retro

A retrospective whose output is **routed, concrete improvements to the toolkit** — not a reflection
essay. Every finding names a durable home and proposes a specific change, so the next session is
faster, smoother, or better-governed than this one.

**Use when** a long or notable session is wrapping up. Skip trivial sessions — an honest
"nothing worth changing" is a valid retro; never manufacture findings to look thorough.

## The bar

Surface a finding only if it would **change how the next session goes**. For each, ask: is it
*recurring or explicitly flagged*, *actionable*, and *generalizable beyond this one session*? If
not, drop it. Three routed improvements beat a page of observations.

## 1. Assess the session

Reconstruct what happened — the goal, what changed, which skills/tools were used — then look across
these lenses. The first three are the user's core asks; the rest often surface the best findings:

- **Repetitive work** — what did we do more than once, or the slow way? What reaches the same
  result faster next time?
- **Bottlenecks** — where did we stall? Permission prompts, denied/missing tools, slow verify
  loops, ambiguity that needed a round-trip, context we lacked.
- **Feedback → rule** — what did the user correct, prefer, or confirm that should bind future work?
- **What worked — keep it** — an approach worth codifying as the default next time, not just this time.
- **Wrong turns** — where did we backtrack? Root cause (missing context, wrong assumption, vague
  spec) and what would have prevented it.
- **Rediscovered knowledge** — facts we had to re-derive or re-read that should have been recorded.
- **Decisions worth pinning** — a choice that shouldn't be re-litigated next time.
- **Calibration** — did the agent over/under-verify, over-ask, or over-explain?

## 2. Route each finding to a durable home

A finding with no destination is just a complaint. Map each to where it lives and the tool that
puts it there:

| Finding | Durable home | Via |
|---|---|---|
| A repeatable multi-step procedure | a new skill / slash command | `write-a-skill` |
| A tool call that kept prompting for permission | settings allowlist | `fewer-permission-prompts`, `update-config` |
| An "always / whenever X" behaviour | a hook | `update-config` |
| A correction or working preference | a **feedback** memory, or an edit to the skill | memory / Edit |
| A project fact, rule, or constraint | `CLAUDE.md` / `AGENTS.md` / project docs | Edit |
| Knowledge we had to rediscover | a **reference** / **project** memory | memory |
| A decision not to re-litigate | an ADR or project memory | `docs/adr/` / memory |
| A skill that misfired or has a fuzzy trigger | that skill's description or body | Edit |

## 3. Report, then apply

Present findings grouped by home, highest-leverage first, each as: **what happened → the change →
where it lands**. Then **offer to apply them**, invoking the routed tool for each. Confirm before any
outward-facing or hard-to-reverse change; batch the small local ones.

## Common mistakes

- **Findings with no home** — "communication could be better" routes nowhere. Make it concrete or cut it.
- **Manufacturing findings** — inventing problems to look thorough. Nothing-to-change is a real outcome.
- **A rule from a single, unflagged instance** — capture explicit corrections; don't legislate one-offs.
- **Re-litigating settled decisions** — pin them, don't reopen them.
- **A report nobody acts on** — the value is the applied change, not the write-up.

## Across sessions

The strongest signal is a theme that recurs. Optionally keep a one-line-per-session log (a memory,
or a `retros/` note) so patterns accumulate, and promote a theme to a rule once it shows up twice.
To trigger this every time, wire a `Stop`-hook *reminder* via `update-config` — the reminder is
automatic; the assessment stays this skill.
