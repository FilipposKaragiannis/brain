# workstream

A GitHub-native, solo spec-driven workflow. Grill a plan into shared understanding, publish a **concise** epic issue, slice it into independently-shippable sub-issues, track progress with GitHub's native sub-issue rollup, ship one slice at a time, and open a reviewed PR.

Built for working alone with issues you actually enjoy reading: short bodies, size tags, native progress bars — no PRD walls of text.

## Conventions

The whole plugin shares two homes (created/seeded by `init`):

- **Domain vocabulary** → the `## Glossary` section of `CLAUDE.md`. One home, used by every skill.
- **Architecture decisions** → `docs/adr/NNNN-slug.md`. One file per hard-to-reverse decision; skills respect them and don't re-litigate.

**Issue model** — GitHub is open/closed only, so state is modelled with labels:

| State | Icon | Meaning |
|---|---|---|
| todo | ○ | open, unassigned |
| in progress | ◐ | open, assigned (`@me`) |
| in review | ⟳ | open + `status:in-review` (a PR is open) |
| done | ✔ | closed (PR merged via `Resolves #n`, or closed directly) |

**Sizes** — `size:S` / `size:M` / `size:L`. Anything that feels **XL → split it**.

**Hierarchy** — 2 tiers: an **epic** (`epic` label) is the parent; **sub-issues** are linked under it so the epic's native progress bar tracks them automatically. A standalone **task** has no parent.

## Setup

Run once per repo:

```
init
```

Verifies `gh` auth + a GitHub remote, creates the labels (`epic`, `size:S|M|L|XL`, `status:in-review`), and stubs `## Glossary` in `CLAUDE.md`.

## The flows

**Big work** — plan it, slice it, ship the slices:

```
grill  →  to-epic  →  to-subissues  →  ship  →  to-pr
 plan      epic        slices         build    reviewed PR
                         │              ▲
                         └──── board ───┘   (watch progress anytime)
```

**Small work** — one self-contained slice:

```
to-task  →  ship  →  to-pr
```

**Architecture work** — start from friction, not a feature:

```
improve  →  (to-epic | to-task)  →  to-subissues  →  ship  →  to-pr
```

If `ship` discovers a chosen issue is too big, it stops and offers `to-subissues` to split it in place (the task becomes the parent).

## The skills

| Skill | What it does |
|---|---|
| **init** | One-time repo setup: checks `gh`/remote, creates labels, seeds `## Glossary`. |
| **grill** | Interview you one question at a time, stress-testing the plan against the codebase and `## Glossary`. Updates the glossary inline; offers ADRs sparingly. Ends pointing at `to-epic`. |
| **to-epic** | Synthesizes the conversation (never re-interviews) into a **concise** parent epic issue — Problem / Solution / Scope / Acceptance, design notes collapsed. |
| **to-subissues** | Slices a parent (epic, or a task being split) into vertical-slice sub-issues — each a thin end-to-end path, size-tagged, optionally `Blocked by #n`, linked under the parent. **Refactor mode**: when the parent is a refactor, each slice is a tiny step that leaves the program green. |
| **to-task** | Captures one small standalone issue (no epic, no decomposition). Ship it directly. |
| **improve** | Architecture on-ramp: finds "deepening" opportunities (shallow→deep modules), renders a visual HTML report, grills the one you pick, then hands it to `to-epic`/`to-task`. Discovers & specs; never implements. |
| **board** | Read-only dashboard for an epic — progress bar + each slice's state, size, and ready/blocked status. Never modifies anything. |
| **ship** | Implements exactly one issue end-to-end: pick it (or suggest the next ready one), advise a split if it's too big, choose a test strategy (TDD / tests-after / none), verify each acceptance criterion, then finish via `to-pr` or a direct close. |
| **to-pr** | Takes verified work to a PR through three hard gates: **tests green → your manual feel-test + approval → commit/push/PR**. Opens the PR with `Resolves #n`, tags `@codex` and `@claude` for review, and marks the issue `status:in-review`. |

## Which skill do I run?

- New feature/change, non-trivial → **grill**
- One small slice → **to-task**
- "This code is painful / hard to test" → **improve**
- Ready to build the next slice → **ship**
- Work's done, want it reviewed and merged → **to-pr**
- "Where's this epic at?" → **board**

## Notes

- `ship` does one issue per run and never pushes — pushing belongs to `to-pr`.
- On the PR path the issue is **not** closed manually; merging the PR closes it (`Resolves #n`) and advances the epic's bar.
- `board` computes progress from sub-issue states immediately; GitHub's own bar can lag a few seconds before it self-heals.
