---
name: epic-plan-review
description: Scrutinize GitHub/workstream epics, PRDs, task breakdowns, and implementation plans for pragmatic planning gaps, flawed assumptions, missing acceptance criteria, risky sequencing, and implementation smells. Use when the user asks an agent to review, scrutinize, stress-test, sanity-check, or find gaps in an epic, issue, plan, task breakdown, or planned implementation before coding.
---

# Epic Plan Review

## Purpose

Review the plan, not the code diff. Ground conclusions in the actual work item, linked tasks, project rules, and current source so feedback is useful and proportionate.

## Workflow

1. Resolve the planning artifact:
   - If the user gives an issue, PRD, URL, or branch, use it.
   - If they only describe "the epic", identify the repo and list plausible open epics; pick only when unambiguous.
   - Fetch the epic body, linked sub-issues, comments, labels, blockers, and current state.

2. Load local context before judging:
   - Read the repo agent guide and any scoped docs it names.
   - Read the ADR/spec/design docs cited by the epic.
   - Inspect the current implementation around each planned touchpoint.
   - Check tests, fixtures, CI gates, and existing guardrails relevant to the plan.

3. Build a compact model of the plan:
   - Goal and non-goals.
   - Slice order and dependencies.
   - Acceptance criteria and verification gates.
   - Assumptions the plan depends on.
   - Files, modules, and interfaces likely to change.

4. Scrutinize along practical axes:
   - Does the proposed design actually satisfy the product/technical goal?
   - Are slice boundaries independently shippable and ordered to reduce risk?
   - Are any acceptance criteria impossible, too vague, or not testable?
   - Are important invariants, compatibility requirements, migration paths, or observability missing?
   - Do implementation details contradict current code, docs, or architecture boundaries?
   - Are tests and verification strong enough for the blast radius?
   - Are out-of-scope items truly separable, or are they hiding a required dependency?

5. Apply the pragmatism filter:
   - Raise only issues that could materially affect correctness, delivery, maintainability, verification, or future work.
   - Do not invent objections just to be adversarial.
   - Prefer "change this part of the plan" over generic concern.
   - Distinguish blockers from manageable risks and optional cleanup.
   - If the plan is mostly sound, say that plainly.

## Evidence Rules

- Cite exact issue numbers, docs, and file paths/lines for concrete findings.
- Clearly separate direct evidence from inference.
- If source access fails, state what could not be inspected and how that limits confidence.
- Do not mark an item "planned", "done", or "covered" until it has been verified in the work item or code.

## Output Shape

Start with the verdict:

- `Sound overall`, `Sound with gaps`, or `Not sound yet`.

Then list findings ordered by severity:

- **Blocker**: likely invalidates the plan or prevents reliable execution.
- **Risk**: likely to cause rework, bugs, or weak verification if left unaddressed.
- **Gap**: missing detail the implementer needs before or during execution.
- **Nice-to-fix**: small improvement, only include when it is genuinely useful.

End with:

- What looks solid.
- Open questions, only if they block confident judgment.
- A concise recommendation for plan edits or sequencing changes.
