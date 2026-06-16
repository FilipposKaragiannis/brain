---
name: review
description: Two-axis review of the changes since a fixed point (commit, branch, tag, merge-base, or a PR) — Standards (does the code follow this repo's documented standards, glossary, and ADRs?) and Spec (does it implement what the originating issue/PRD asked, criterion by criterion?). Runs both axes as parallel sub-agents, keeps them separate, and returns a severity-graded verdict per axis. Complements code-review (bugs/cleanups) and verify (does it actually run). Use when the user wants to review a branch, a PR, work-in-progress changes, or asks to "review since X".
---

# Review

Two-axis review of the diff between a fixed point (commit, branch, tag, merge-base, or a PR) and the work under review:

- **Standards** — does the code conform to this repo's documented standards, `## Glossary`, and ADRs?
- **Spec** — does it implement what the originating issue / PRD asked, **criterion by criterion**?

Both axes run as **parallel sub-agents** (so they don't pollute each other's context); this skill aggregates them, keeps them separate, and stamps a **verdict** on each.

**This is not a bug hunt — stay in lane and point elsewhere for the rest:**

| Question | Skill |
|---|---|
| Does it follow the rules and match the ask? | **review** (this) |
| Are there correctness bugs / cleanups? | `code-review` |
| Does it actually run? | `verify` |

## Process

### 1. Pin the fixed point

- **`review <PR#>` or a PR URL** → PR mode. Read it with `gh pr view <#> --json title,body,baseRefName,headRefName,url`; diff with `gh pr diff <#>`. The fixed point is the PR's base branch; the spec comes from `Resolves/Closes #n` in the PR body.
- **An explicit fixed point** (SHA, branch, tag, `main`, `HEAD~5`) → pass it through; don't be opinionated.
- **Nothing given** → if you're on a non-default branch, default to its merge-base with the default branch and say so ("reviewing against `main`…"); only ask if you're on the default branch with no other signal.

Capture once: `git diff <fixed-point>...HEAD` (three-dot, against the merge-base) and the commit list `git log <fixed-point>..HEAD --oneline`. **Empty diff → STOP** ("nothing to review since X").

### 2. Resolve the spec source

First hit wins:

1. PR mode → `Resolves #n` / `Closes #n` in the PR body.
2. Branch named `ws/<issue#>-slug` → that issue: `gh issue view <n> --json title,body,labels`.
3. Issue references in the commit messages (`#123`, `Closes #45`).
4. A path the user passed.
5. A PRD/spec under `docs/`, `specs/`, or `.scratch/` matching the branch/feature.
6. Nothing → the Spec axis skips and reports "no spec available."

If the issue has a parent epic, fetch it too — its **Scope** and **Out-of-scope** frame the slice (as `ship` treats them).

### 3. Collect the standards sources

Everything that documents how code should be written here:

- `CLAUDE.md` / `AGENTS.md`, and especially its **`## Glossary`** (the domain vocabulary — the diff must use these terms).
- `docs/adr/` — architecture decisions are standards.
- `CONTRIBUTING.md`, any `STYLE.md` / `STANDARDS.md` / `STYLEGUIDE.md`.
- Documented testing conventions (e.g. "tests verify behavior through public interfaces").
- Machine-enforced config (`.editorconfig`, `eslint.*`, `biome.json`, `tsconfig.json`) — note it, but **don't re-check what tooling already enforces**.

Collect the paths; the sub-agent reads them.

### 4. Spawn both axes in parallel

One message, two `Agent` calls (`general-purpose`). For each, read the matching brief from this skill's folder and send it as the agent's instructions, with the dynamic context filled in at the top:

- **Standards** → [STANDARDS.md](STANDARDS.md) + the diff command, commit list, and the standards-source paths from step 3.
- **Spec** → [SPEC.md](SPEC.md) + the diff command, commit list, the spec (path or fetched contents), and the epic scope if any.

Skip the Spec agent if there's no spec; note it in the report.

### 5. Aggregate + verdict

Present the two reports under `## Standards` and `## Spec`, verbatim or lightly cleaned. **Do not merge or rerank** — the axes are deliberately independent so neither masks the other.

Both briefs grade findings on one scale: 🔴 **blocker** (must fix before merge) · 🟡 **should-fix** (real, but a judgement call) · ⚪ **nit** (minor). Stamp each axis with a verdict from its worst finding:

- 🔴 **FAIL** — at least one blocker.
- 🟡 **PASS WITH NITS** — only should-fix / nits.
- 🟢 **PASS** — clean.

End with one line: the verdict per axis + the single worst finding overall. Then offer the next step:

- PR mode, if the user wants it on the record → offer to post the verdict + findings as a PR comment (`gh pr comment`). **Confirm before posting.**
- Both axes **PASS / PASS WITH NITS** → it's ready to open / advance the PR (on the workstream flow, hand to `to-pr`).
- Any **FAIL** → recommend fixing the blockers and re-running review (on the workstream flow, back to `ship`).

## Why two axes

A change can pass one and fail the other:

- Follows every standard but builds the wrong thing → **Standards pass, Spec fail.**
- Does exactly what the issue asked but breaks the conventions → **Spec pass, Standards fail.**

Separate reports stop one axis from masking the other.
