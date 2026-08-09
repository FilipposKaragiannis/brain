---
name: to-epic
description: Synthesize the current conversation into a concise PRD and publish it as a parent ("epic") GitHub issue. Scans the code for existing invariants the epic's new capabilities would invalidate and adds them as acceptance lines. Does NOT interview — that is grill's job. Use after grill, or when the feature is already clear from the conversation.
disable-model-invocation: true
---

# workstream: to-epic

Turn the current conversation and codebase understanding into a concise PRD, published as a parent ("epic") GitHub issue.

**Do NOT interview.** All questions belong to `grill`. Synthesize what you already know. If a load-bearing piece is genuinely missing (e.g. no out-of-scope was ever discussed), either:

- make a reasonable inference and **flag it as an assumption** in the body for the user to correct, or
- if it's truly blocking, name the gap and suggest a quick `grill` round.

Never start a full interview here.

## Process

1. If you haven't explored the repo yet, do so. Use the `## Glossary` vocabulary throughout, and respect any ADRs in `docs/adr/` for the area you're touching.
2. Identify, at a high level, the test seams for the feature (prefer existing seams; propose new ones at the highest point possible — the fewer seams across the feature, the better, ideally just one). Check the seams match the user's expectations before drafting around them. Keep this brief — detail belongs in the sub-issues, not the epic.
3. **Ask what this epic invalidates.** New capabilities routinely break assumptions that were only ever correct because the capability didn't exist yet — and those breaks are invisible until something later in the epic ships and quietly exercises them. For each capability the epic introduces, check the existing code for assumptions that hold only in the capability's absence (e.g. a check that validates "some" state where the new capability requires validating a *specific* one). This is a code fact, not a design decision — go find it, don't ask the user to guess. Add each one found as its own line in `## Acceptance`, phrased as a binary check like every other line (e.g. "existing `<check>` still enforces `<specific invariant>` once `<new capability>` ships") — don't try to resolve it here; `to-subissues` will route it to a slice or a dedicated verification-closeout slice.
4. Draft the epic body using the template below. **Keep it scannable** — terse bullets, no user-story spam. Push any verbose design detail into the collapsed `<details>` block so the issue reads short by default.
5. Show the draft to the user. On approval, publish:

   ```
   gh issue create --title "<feature name>" --body "<body>" --label epic
   ```

   Report the epic's issue number and URL — `to-subissues` needs it.

## Epic template

```
## Problem

<2-3 sentences — the problem from the user's perspective.>

## Solution

<2-4 sentences — the approach from the user's perspective.>

## Scope

- In:  <terse bullets of what's included>
- Out: <explicit non-goals — the things a reader might assume are included but aren't>

## Acceptance

- [ ] <binary, testable, feature-level outcome>
- [ ] ...

<details><summary>Design notes</summary>

<Optional. Key decisions, or a schema / contract / type snippet — only if it encodes a decision more precisely than prose can. Trim to the decision-rich part, not a working demo. Collapsed so the issue stays short.>

</details>
```

## Rules

- **No file paths or code in the open body** — they go stale fast. The only code allowed is a decision-encoding snippet inside `<details>`.
- **Acceptance criteria are binary** pass/fail. No "should be good / clean / fast / appropriate." Rewrite any subjective criterion with a concrete, checkable condition.
- **Never skip Out-of-scope.** If the user never mentioned non-goals, infer reasonable ones and flag them as assumptions.
- **Never skip the invalidation scan (step 3).** An epic that introduces a genuinely new capability and finds nothing it invalidates is the exception, not the default — say so explicitly ("checked for invalidated invariants — found none") rather than silently omitting the step.
- **Self-contained:** a fresh agent reading only this issue plus the codebase must be able to understand the feature.

Next: run `to-subissues <epic#>` to slice it into independently-shippable sub-issues.
