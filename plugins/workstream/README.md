# workstream

A GitHub-native, solo spec-driven workflow. Grill a plan into shared understanding, publish a **concise** epic issue, slice it into independently-shippable sub-issues, track progress with GitHub's native sub-issue rollup, ship one slice at a time, and open a reviewed PR.

Built for working alone with issues you actually enjoy reading: short bodies, size tags, native progress bars — no PRD walls of text.

## Conventions

The whole plugin shares three homes:

- **Domain vocabulary** → the `## Glossary` section of `CLAUDE.md` (seeded by `init`). One home, used by every skill.
- **Architecture decisions** → `docs/adr/NNNN-slug.md`. One file per hard-to-reverse decision; skills respect them and don't re-litigate.
- **Code standards** → the repo's existing standards docs (`CLAUDE.md`/`AGENTS.md` conventions, `docs/coding-conventions.md`, any `STANDARDS.md`/`STYLE.md`). `grill` challenges plans against them, `ship` designs and implements to them, and `two-axis-review`'s Standards axis grades a breach against them P0. The repo authors these; the skills only read them. The design rules that have no compiler to catch them (pure-over-stateful, immutability, `T?`-over-bool, minimal state, abstractions-earn-their-place) live here — keep them **checkable**, so review can flag a breach as a P0 rather than a vague nit.

**Issue model** — GitHub is open/closed only, so state is modelled with labels:

| State | Icon | Meaning |
|---|---|---|
| todo | ○ | open, unassigned |
| in progress | ◐ | open, assigned (`@me`) |
| in review | ⟳ | open + `status:in-review` (a PR is open) |
| done | ✔ | closed (PR merged via `Resolves #n`, or closed directly) |

**Sizes** — `size:S` / `size:M` / `size:L`. Anything that feels **XL → split it**.

**Hierarchy** — 2 tiers: an **epic** (`epic` label) is the parent; **sub-issues** are linked under it so the epic's native progress bar tracks them automatically. A standalone **task** has no parent — unless it's filed with `to-task <epic#>`, which attaches it as a native sub-issue of an already-decomposed epic (the late-addition path).

**Dependency graph** — one model, two renderers. `scripts/epic_graph.py <owner/repo> <epic#>` computes readiness waves and the size-weighted critical path from native `blocked_by` edges; `skills/_shared/dependency-graph.md` pins exactly how that JSON becomes `board --plan`'s SVG and its optional Mermaid comment, so the two views can't drift apart. Analysis lives once, in the script — a renderer only formats.

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
                         └──── board ────┘   (watch progress anytime — flags + offers to fix drift automatically)
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
| **to-epic** | Synthesizes the conversation (never re-interviews) into a **concise** parent epic issue — Problem / Solution / Scope / Acceptance, design notes collapsed. Scans the code for existing invariants the epic's new capabilities would invalidate and adds them as acceptance lines. |
| **to-subissues** | Slices a parent (epic, or a task being split) into vertical-slice sub-issues — each a thin end-to-end path, size-tagged, optionally `Blocked by #n` (written natively, not just in prose), linked under the parent. Assigns every epic acceptance line to a slice or a dedicated verification-closeout slice, and flags merge-order `Contends with` collisions between parallel slices. **Refactor mode**: when the parent is a refactor, each slice is a tiny step that leaves the program green. |
| **to-task** | Captures one small issue (no decomposition) — standalone by default, or `to-task <epic#>` to attach it as a native sub-issue of an existing epic (writing any real blocker as a native edge too). Ship it directly. |
| **improve** | Architecture on-ramp: finds "deepening" opportunities (shallow→deep modules), renders a visual HTML report, grills the one you pick, then hands it to `to-epic`/`to-task`. Discovers & specs; never implements. |
| **board** | Dashboard for an epic — progress bar + each slice's state, size, and ready/blocked status (computed from the native dependency graph, not body text). Read-only in the common case; if the data it already fetched shows drift (a prose `Blocked by` with no native edge, a closed issue still labeled `status:*`, a merged PR that didn't auto-close the issue) it flags it and offers a confirmed fix — silent on a healthy epic, nothing to run separately. `board <epic#> --plan` renders an execution plan instead — a wave/blocked-by table plus an SVG dependency graph off `scripts/epic_graph.py`'s JSON model, with an optional Mermaid mirror to a pinned epic comment. |
| **ship** | Implements exactly one issue end-to-end: pick it (or suggest the next ready one), re-check its acceptance criteria against current code in case a neighbouring slice already delivered part of it, advise a split if it's too big, run its **default behavior-test workflow** (deliberate API design → implement → meaningful behavior + edge-case tests through public interfaces), auto-selecting a TDD or no-test variant only when the work warrants it, verify each acceptance criterion, then finish via `to-pr` or a direct close. |
| **to-pr** | Takes verified work to a PR through three hard gates: **tests green → your manual feel-test + approval → commit/push/PR**. Opens the PR with `Resolves #n` (no bot tags in the body), warns if the base isn't the default branch (merge won't auto-close), then tags `@codex` and `@claude` for review in separate follow-up comments, and marks the issue `status:in-review`. |
| **tdd-task** | The opt-in **red-green** variant `ship` selects for algorithmic logic or a bug with a clear repro (or via `--tdd`): one failing test → minimal code → refactor, repeat. Its test-quality and design notes (public-interface tests, meaningful edge cases, deep modules, mocking, interface design) are the **same bar** `ship`'s default uses — not TDD-specific. |

## Which skill do I run?

- New feature/change, non-trivial → **grill**
- One small slice → **to-task**
- "This code is painful / hard to test" → **improve**
- Ready to build the next slice → **ship**
- Work's done, want it reviewed and merged → **to-pr**
- "Where's this epic at?" → **board** (or **board --plan** for what to start next / what runs in parallel) — it also flags and offers to fix any drift it notices while it's in there
- Want a read-only check before the PR → the standalone **`two-axis-review`** skill (see Companion below)

## Companion

**`two-axis-review`** is a separate, standalone skill (not bundled here) that pairs naturally with this flow: a read-only, two-axis review of the diff — **Standards** (does it follow `## Glossary` / ADRs / this repo's documented conventions, plus a baseline set of Fowler code smells?) and **Spec** (does it implement the issue's acceptance criteria?) — with every finding graded P0/P1/P2. It runs in PR mode too (`two-axis-review <PR#>`), where it can post each finding as its own standalone PR comment. It slots between `ship` and `to-pr`. Run it alongside `code-review` (bugs/cleanups) and `verify` (does it run) for full coverage.

## Notes

- `ship` does one issue per run and never pushes — pushing belongs to `to-pr`.
- On the PR path the issue is **not** closed manually; merging the PR closes it (`Resolves #n`) and advances the epic's bar.
- `board` computes progress from sub-issue states immediately; GitHub's own bar can lag a few seconds before it self-heals.
