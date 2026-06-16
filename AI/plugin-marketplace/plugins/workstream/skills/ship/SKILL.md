---
description: Implement one issue end-to-end (an epic sub-issue or a standalone to-task issue) — pick it or let it suggest the next ready one, advise a sub-issue split first if the work is too complex, choose a test strategy (TDD, tests-after, or none), verify against acceptance criteria, then either hand off to to-pr (moving it to "in review") or close it directly.
---

# workstream: ship

Implement exactly ONE issue per run — a sub-issue from an epic, or a standalone `to-task` issue.

## 1. Pick the work

- `ship <#>` → that specific issue (an epic sub-issue or a standalone task).
- bare `ship [epic#]` → resolve the epic (as `board` does), compute the ready slices (open, with every `Blocked by #N` already closed), **suggest the lowest-order ready one, and ask the user to confirm or pick another.** Never auto-start without confirmation.
- If the chosen issue is blocked, list its open blockers and refuse unless the user explicitly insists.

## 2. Load context

```
gh issue view <#> --json title,body,labels
```

Also read: the parent epic (if this issue has one), `CLAUDE.md` (conventions + `## Glossary`), any ADRs in `docs/adr/` for the area, and the existing code you'll touch. Mark the issue in progress: `gh issue edit <#> --add-assignee @me`.

## 3. Gauge complexity — advise a split if it's too big

Before committing to implementation, judge the real complexity from the code you just read: files touched, integration points, ambiguity in the acceptance criteria, and risk of breaking existing behavior. If the work is effectively **XL** — too big to ship as one clean vertical slice — **STOP and advise a split** instead of ploughing ahead:

- Propose 2-4 sub-issues along natural seam lines, each a thin end-to-end slice.
- Offer to create them under THIS issue: run `to-subissues #<this>` — that links them as sub-issues, so this issue becomes their parent and tracks their progress natively.
- Ask: **split into sub-issues (recommended), or implement as-is anyway?**

Only continue to implement when the user chooses to, or the work is genuinely S/M. (A standalone `to-task` issue that turns out complex simply becomes a parent once sub-issues are added under it — no separate "promote" step.)

## 4. Choose the test strategy

Pick the strategy that fits the task, state a one-line rationale, and let the user override (`--tdd` / `--tests-after` / `--no-tests`):

- **tdd** (red-green-refactor; one test → one implementation, vertical slices) — logic-heavy / algorithmic work, or a bug with a clear repro. When in TDD mode, follow the `tdd-task` skill.
- **tests-after** — implement the slice, then write meaningful tests covering its behavior — wiring / integration / CRUD / UI work.
- **none** — purely declarative (config, enums, data-only DTOs, docs). Say so explicitly.

Either way, tests verify behavior through public interfaces, never implementation details — they should survive an internal refactor.

## 5. Plan, then implement

Present a short plan: approach, files to create/modify, the tests you'll write, and what you will NOT touch (the issue's non-goals, plus the epic's Out-of-scope if it has a parent). On user OK, implement following the existing codebase conventions and `CLAUDE.md`.

- Stay strictly in scope — no "while I'm here" changes, no unrelated refactors or bug fixes.
- If implementation reveals the spec is wrong, ambiguous, or impossible, STOP and tell the user rather than improvising.

## 6. Build and verify

Always build; always run the relevant tests. Then verify EACH acceptance criterion from the issue → pass / fail with `file:line` evidence. If anything fails, fix it (keeping new tests green) or explain why it can't be fixed. Do not proceed while the build is red or a criterion fails.

## 7. Decide how to finish — do NOT auto-close

The build is green and every acceptance criterion passes. **Leave the issue open** (still assigned = in progress) and present two paths:

> "Verified #<n>. Open a reviewed PR (moves it to *in review*), or close it directly without a PR? (pr / close)"

**A) Open a PR (default).** Run `to-pr` — validate the suite, get the user's feel-test approval, then commit, push, and open a reviewed PR. This moves the issue to **in review** (`to-pr` adds `status:in-review`; the issue stays open). When the PR merges, GitHub auto-closes the issue via `Resolves #<n>` — and if it has a parent epic, that epic's native progress bar advances.

**B) Close directly, no PR.** For trivial work that needs no PR:

```
gh issue close <#> --comment "<one-line summary — acceptance criteria met>"
```

The bar advances immediately (for an epic child).

Then, if this issue has a parent epic, print the updated `board` for it; otherwise just confirm the new state.

## Rules

- One issue per run. If asked to do more, refuse and tell the user to run `ship` again for the next one.
- Respect the issue's non-goals (and the epic's Out-of-scope, if it has a parent).
- **On the PR path, never close the issue** — the merge closes it (path A). Only path B closes directly.
- **Never push** as part of `ship` — pushing belongs to `to-pr`.
