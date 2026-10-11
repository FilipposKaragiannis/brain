---
name: improve
description: Find deepening opportunities in a codebase. Refactors that turn shallow modules into deep ones for testability and navigability, rendered as a visual HTML report with before and after diagrams, each citing the standards rule it serves. Use when the user wants to improve the architecture, find refactoring opportunities, consolidate tightly coupled modules, or make a codebase more testable.
---

# Improve

Surface architectural friction and propose **deepening opportunities**: refactors that turn
shallow modules into deep ones. Discover and specify; never implement here. The vocabulary
(module, interface, seam, adapter, depth, leverage, locality), the deletion test and the
standards mapping are in [codebase-design](../codebase-design/SKILL.md); use its words exactly.

## 1. Explore

Scope before you scan. Deepening pays off where code keeps changing, so weight the parts that
changed recently (`git log --oneline -200 --name-only`) over stable ones. When the user named an
area, take it and skip the inference.

Read the `## Glossary` in `AGENTS.md` (or `CLAUDE.md`) and `docs/adr/` first: the glossary names
good seams; the ADRs record decisions not to re-litigate. Read the standards block in `AGENTS.md`.

Then spawn an exploration subagent (the `explorer` role when the flow plugin is installed, else
a general read-only subagent) with the area, the vocabulary and these questions:

- Where does understanding one concept mean bouncing between many small modules?
- Where is a module shallow, its interface nearly as complex as its implementation?
- Where were pure functions extracted for testability while the bugs hide in how they are
  called (no locality)?
- Where do tightly coupled modules leak across their seams?
- What is untested, or hard to test through its current interface?

Apply the deletion test to every suspect: would deleting it concentrate complexity, or only
move it? "Concentrates" is the signal.

## 2. Present the candidates as an HTML report

Write one self-contained file to `${TMPDIR:-/tmp}/improve-<timestamp>.html`, open it
(`open` on macOS, `xdg-open` on Linux) and print the absolute path. Scaffold, diagram patterns
and styling: [HTML-REPORT.md](HTML-REPORT.md). Mermaid for graph-shaped relationships, hand-built
divs or SVG for the editorial visuals. Each candidate is a card:

- **Files**: the modules involved.
- **Problem**: the friction, in the glossary's words.
- **Solution**: what changes, in plain English, no interface proposal yet.
- **Benefits**: locality and leverage, and how the tests improve.
- **Rules served**: the standards ids this deepening satisfies (D-01, D-02, D-04, S-01, S-02,
  T-12 are the usual ones), and any it strains.
- **Before and after**: side by side, drawn, showing the shallowness and the deepening.
- **Dependencies**: the category of each dependency per
  [DEEPENING.md](../codebase-design/DEEPENING.md), which decides how the deep module is tested.
- **Strength**: `Strong`, `Worth exploring` or `Speculative`, as a badge.

An ADR conflict is shown only when the friction is real enough to reopen the ADR, with a warning
callout naming it. End with **Top recommendation**: the first candidate to take and why.

In the chat, list the candidates in one line each (name, strength, the rules served) with the
report path, then ask: "Which of these would you like to explore?" and stop.

## 3. Specify the chosen candidate

Walk the design tree with the owner one question at a time, as the flow's interviewer does:
constraints, the dependency categories, the shape of the deepened module, what sits behind the
seam, which tests survive. Facts you look up; decisions are the owner's. Record a new term in the
`## Glossary` at once; offer an ADR only for a hard-to-reverse, surprising, real trade-off, and
when the owner rejects a candidate for a load-bearing reason, so the next run does not
re-suggest it. To explore alternative interfaces, run
[DESIGN-IT-TWICE.md](../codebase-design/DESIGN-IT-TWICE.md).

## 4. Hand off

A deepening is implemented through the flow, never here:

- **Several slices** (a refactor that must land green after every step): an epic, sliced as
  Fowler micro-steps. With the flow plugin: create the epic through the tracker adapter and
  run `flow:plan` on it. Without it: write the epic body (problem, solution, scope, acceptance
  as binary lines) for the owner to file.
- **One self-contained deepening**: one task with acceptance lines and a size, created the same
  way, then `flow:next`.

Say which you recommend and why, and stop.
