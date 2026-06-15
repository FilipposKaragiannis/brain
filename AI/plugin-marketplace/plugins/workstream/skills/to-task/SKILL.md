---
name: to-task
description: Capture a single small piece of work as one standalone GitHub issue — concise body, size label, no epic and no decomposition. Use when the work is one vertical slice that doesn't warrant an epic + sub-issues, then ship it directly.
---

# workstream: to-task

For work small enough to be ONE vertical slice — no epic, no decomposition. Produces a single standalone issue you can `ship` directly.

## When to use

- The work is a single, demoable end-to-end slice (roughly **S or M**).
- If it feels **L across several concerns, or XL**, stop — it wants an epic: use `to-epic` then `to-subissues` instead.
- If you only discover it's too big at execution time, don't worry: `ship` gauges complexity and will advise splitting the task into sub-issues (the task itself becomes their parent).

## Process

1. If you haven't explored the repo, do so. Use the `## Glossary` vocabulary; respect ADRs in `docs/adr/`.
2. Synthesize the task from the conversation — **do not interview** (that's `grill`'s job). Flag any load-bearing assumption.
3. Draft the issue with the concise template below; size it S/M/L.
4. Show the draft. On approval, publish:

   ```
   gh issue create --title "<title>" --body "<body>" --label "size:<S|M|L>"
   ```

   No `epic` label, no parent. Report the issue number/URL.

## Task template (keep it to ~6 lines)

```
## What

<1-3 sentences — the end-to-end slice. Behavior, not a layer-by-layer breakdown.>

## Acceptance

- [ ] <binary criterion>
- [ ] ...

Size: <S|M|L>
```

- No file paths or code (exception: a decision-encoding snippet, trimmed to the decision).

Next: run `ship <#>` to implement it.
