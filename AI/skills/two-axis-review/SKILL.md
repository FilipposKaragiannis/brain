---
name: two-axis-review
description: Review the changes since a fixed point (commit, branch, tag, merge-base, or a PR) along two axes — Standards (does the code follow this repo's documented coding standards, `## Glossary`, and ADRs?) and Spec (does the code match what the originating issue/PRD asked for?). Runs both reviews in parallel sub-agents, grades findings P0/P1/P2, and reports them side by side. In PR mode, can post each finding as its own standalone PR comment. Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X".
---

Two-axis review of the diff between a fixed point (commit, branch, tag, merge-base, or a PR) and the work under review:

- **Standards** — does the code conform to this repo's documented coding standards, `## Glossary`, and ADRs?
- **Spec** — does the code faithfully implement the originating issue / PRD / spec?

Both axes run as **parallel sub-agents** so they don't pollute each other's context, then this skill aggregates their findings.

## Process

### 1. Pin the fixed point

- **`two-axis-review <PR#>` or a PR URL** → PR mode. Read it with `gh pr view <#> --json title,body,baseRefName,headRefName,url`; diff with `gh pr diff <#>`. The fixed point is the PR's base branch; the spec comes from `Resolves/Closes #n` in the PR body.
- **An explicit fixed point** (SHA, branch, tag, `main`, `HEAD~5`) → pass it through; don't be opinionated.
- **Nothing given** → if you're on a non-default branch, default to its merge-base with the default branch and say so ("reviewing against `main`…"); only ask if you're on the default branch with no other signal.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Before going further, confirm the fixed point resolves (`git rev-parse <fixed-point>`) and the diff is non-empty. A bad ref or empty diff should fail here — not inside two parallel sub-agents.

### 2. Identify the spec source

Look for the originating spec, in this order:

1. PR mode → `Resolves #n` / `Closes #n` in the PR body.
2. Issue references in the commit messages (`#123`, `Closes #45`, GitLab `!67`, etc.) — fetch via `gh issue view` (GitHub) or the equivalent for this repo's tracker.
3. A path the user passed as an argument.
4. A PRD/spec file under `docs/`, `specs/`, or `.scratch/` matching the branch name or feature.
5. If nothing is found, ask the user where the spec is. If they say there isn't one, the **Spec** sub-agent will skip and report "no spec available".

If the issue has a parent epic, fetch it too — its **Scope** and **Out-of-scope** frame the slice.

### 3. Identify the standards sources

Everything that documents how code should be written here:

- `CLAUDE.md` / `AGENTS.md`, and especially its **`## Glossary`** (the domain vocabulary — the diff must use these terms).
- `docs/adr/` — architecture decisions are standards. A diff that contradicts an accepted ADR is a violation; cite it.
- `CODING_STANDARDS.md`, `CONTRIBUTING.md`, any `STYLE.md` / `STANDARDS.md` / `STYLEGUIDE.md`.
- Machine-enforced config (`.editorconfig`, `eslint.*`, `biome.json`, `tsconfig.json`) — note it, but **don't re-check what tooling already enforces**.

On top of whatever the repo documents, the Standards axis always carries the **smell baseline** below — a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell.
- **Always a judgement call.** A baseline smell can never be graded P0 — it's a labelled heuristic ("possible Feature Envy"), not a rule the repo agreed to — and, like any standard here, skip anything tooling already enforces.

Each smell reads *what it is* → *how to fix*; match it against the diff:

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

### 4. Spawn both sub-agents in parallel

Send a single message with two `Agent` tool calls. Use the `general-purpose` subagent for both. Both briefs grade every finding on one scale:

- **P0** — a hard violation: a documented-standard breach, `## Glossary` terminology drift, an ADR contradiction, a required spec criterion missing/wrong, or scope creep into a stated non-goal. Must fix before merge.
- **P1** — should-fix: a real deviation that's still a judgement call, an undocumented-but-sensible convention, a baseline smell, or a partial spec criterion.
- **P2** — nit: minor or cosmetic.

**Standards sub-agent prompt** — include:

- The full diff command and commit list.
- The list of standards-source files you found in step 3 (including `## Glossary` and `docs/adr/`), **plus the smell baseline from step 3** pasted in full — the sub-agent has no other access to it.
- The brief: "Report — per file/hunk where relevant — (a) every place the diff violates a documented standard, contradicts an ADR, or drifts from `## Glossary` terminology: cite the standard/ADR/glossary entry (file + the rule) and, for glossary drift, the canonical term it should use; and (b) any baseline smell you spot: name it and quote the hunk. Grade each finding P0/P1/P2 per the scale above — baseline smells never exceed P1. Skip anything tooling enforces. Under 400 words."

**Spec sub-agent prompt** — include:

- The diff command and commit list.
- The path or fetched contents of the spec, and the epic scope if any.
- The brief: "Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the diff that wasn't asked for (scope creep) — cross-check the issue's Non-goals and the epic's Out-of-scope; (c) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding and grade it P0/P1/P2 per the scale above. Under 400 words."

If the spec is missing, skip the Spec sub-agent and note this in the final report.

### 5. Aggregate + verdict

Present the two reports under `## Standards` and `## Spec` headings, verbatim or lightly cleaned. Do **not** merge or rerank findings — the two axes are deliberately separate (see _Why two axes_).

Stamp each axis with a verdict from its worst finding: **FAIL** (any P0) · **PASS WITH NOTES** (only P1/P2) · **PASS** (clean).

End with a one-line summary: the verdict per axis, total findings per axis, and the worst issue _within each axis_ (if any). Don't pick a single winner across axes — that's the reranking the separation exists to prevent.

### 6. Post findings (PR mode only)

If in PR mode and the user wants it on the record, **confirm before posting.** Then post **each finding as its own standalone PR comment** — one `gh pr comment <PR#> --body "..."` call per finding, never bundled into a single comment. Format each:

`**[P0] Standards** — path:line — <what's wrong> — <standard/ADR/glossary entry it breaks> — <the fix>`

(swap `Standards`/`P0` for the finding's actual axis and grade). After all individual finding comments, post one final standalone comment with the verdict per axis and the single worst finding overall.

## Why two axes

A change can pass one axis and fail the other:

- Code that follows every standard but implements the wrong thing → **Standards pass, Spec fail.**
- Code that does exactly what the issue asked but breaks the project's conventions → **Spec pass, Standards fail.**

Reporting them separately stops one axis from masking the other.
