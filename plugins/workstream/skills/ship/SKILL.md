---
name: ship
description: Implement one workstream issue end-to-end, from picked to verified against its acceptance criteria. Use when the user wants to ship, implement, or start work on a workstream issue (an epic sub-issue or a standalone to-task issue).
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

Also read: the parent epic (if this issue has one), `CLAUDE.md` (conventions + `## Glossary`), the repo's **code-standards docs** (e.g. `AGENTS.md` conventions, `docs/coding-conventions.md`, any `STANDARDS.md`), any ADRs in `docs/adr/` for the area, and the existing code you'll touch. Mark the issue in progress: `gh issue edit <#> --add-assignee @me`.

## 3. Gauge complexity — advise a split if it's too big

Before committing to implementation, judge the real complexity from the code you just read: files touched, integration points, ambiguity in the acceptance criteria, and risk of breaking existing behavior. If the work is effectively **XL** — too big to ship as one clean vertical slice — **STOP and advise a split** instead of ploughing ahead:

- Propose 2-4 sub-issues along natural seam lines, each a thin end-to-end slice.
- Offer to create them under THIS issue: run `to-subissues #<this>` — that links them as sub-issues, so this issue becomes their parent and tracks their progress natively.
- Ask: **split into sub-issues (recommended), or implement as-is anyway?**

Only continue to implement when the user chooses to, or the work is genuinely S/M. (A standalone `to-task` issue that turns out complex simply becomes a parent once sub-issues are added under it — no separate "promote" step.)

## 4. Test the work — one default, two escapes you choose

There is **one default approach**. The two escapes exist for narrow cases and **you decide when they apply** — don't make the user pick a strategy up front. State in one line which you're using and why.

**Default — behavior tests after a deliberate design.** For almost all work (features, wiring, integration, CRUD, UI, APIs):

1. **Design the abstraction first.** Decide the public interface/API deliberately before implementing — small surface, dependencies injected at the boundaries, results returned over hidden mutation. See [interface-design.md](../tdd-task/interface-design.md) and [deep modules](../improve/LANGUAGE.md).
2. **Implement** the slice following `CLAUDE.md` and existing conventions.
3. **Write behavior tests from the acceptance criteria** — not from re-reading your own implementation, which only mirrors its blind spots. Through public interfaces only; mock only at system boundaries. Full quality bar, including which edge cases earn a test: [tests.md](../tdd-task/tests.md) and [mocking.md](../tdd-task/mocking.md).
4. **Confirm each test has teeth.** For every test, state in a phrase why it would fail if the behavior were wrong. If you can't, it's noise — cut it or sharpen it.
5. **Never bend core code to be testable.** If something is hard to test, fix the _interface_, not the implementation — see [tests.md](../tdd-task/tests.md) for what that looks like and why it's a defect.

**Escape — `--tdd` (red-green-refactor).** Choose this yourself for **logic-heavy / algorithmic** work, or a **bug with a clear repro** (write the failing repro test first — the cheapest proof you reproduced it). Follow the [tdd-task](../tdd-task/SKILL.md) skill. Same quality bar as the default; the only difference is test-first, one test → one implementation.

**Escape — `--no-tests`.** Choose this yourself for **purely declarative** changes (config, enums, data-only DTOs, docs) — nothing with behavior to pin. Say so explicitly.

The user can still force a path with `--tdd` / `--no-tests`; absent that, you judge. Either way, tests verify behavior through public interfaces, never implementation details — they survive an internal refactor.

## 5. Plan, then implement

Present a short plan: approach, files to create/modify, the tests you'll write, what you will NOT touch (the issue's non-goals, plus the epic's Out-of-scope if it has a parent), and **how the design honours the repo's code standards** — name the specific invariants in play (e.g. pure-over-stateful, `T?`-over-bool, minimal state, immutability, abstractions-earn-their-place) so conformance is a conscious choice up front, not a hope. On user OK, implement following those standards and `CLAUDE.md`.

- Stay strictly in scope — no "while I'm here" changes, no unrelated refactors or bug fixes.
- If implementation reveals the spec is wrong, ambiguous, or impossible, STOP and tell the user rather than improvising.

## 6. Build and verify

Always build; always run the relevant tests. Then verify EACH acceptance criterion from the issue → pass / fail with `file:line` evidence. If anything fails, fix it (keeping new tests green) or explain why it can't be fixed. Do not proceed while the build is red or a criterion fails.

Then **walk the diff against the code standards.** The design invariants are behaviour-preserving, so green tests never flag a violation — check the actual diff against the standards docs, not your memory of them. For a thorough pass, run the `review` skill (its Standards axis treats a documented-rule breach as a blocker).

**Then consider the docs.** If the change altered behaviour or structure in an area that carries living documentation, update that documentation in the *same* slice — name which docs you checked and whether they needed changing. Stale docs are a defect, not a follow-up.

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
