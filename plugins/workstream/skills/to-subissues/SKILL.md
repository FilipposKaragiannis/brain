---
name: to-subissues
description: Break a parent issue — an epic, or a task that grew too big — into concise, independently-shippable vertical-slice sub-issues on GitHub, each size-tagged (S/M/L), optionally blocked-by another, and linked under the parent so progress rolls up natively. Use after to-epic, or when ship advises a split.
disable-model-invocation: true
---

# workstream: to-subissues

Slice a parent issue — an **epic**, or a **task** that turned out too big (`ship` sends you here) — into **vertical-slice** sub-issues (tracer bullets). Each slice cuts a thin but COMPLETE path through ALL layers end-to-end (schema, API, UI, tests) — never a horizontal slice of a single layer.

## 1. Resolve the parent

Take the parent issue number (an epic, or a task you're splitting) from `$ARGUMENTS`, or ask for it. Fetch and read it fully:

```
gh issue view <epic#> --json number,title,body
```

## 2. Explore (if needed)

If you haven't explored the codebase, do so. Titles and bodies use the `## Glossary` vocabulary; respect ADRs in `docs/adr/` for the area you're touching.

## 3. Draft the slices

- Each slice delivers a narrow but COMPLETE path through every layer; a finished slice is demoable or verifiable on its own.
- Prefer many thin slices over few thick ones.
- **Size** each slice **S / M / L**. Anything that feels **XL → split it** before publishing (flag it and propose the split).
- **Sequence** the slices in intended order. If a slice genuinely cannot start until another is done, note `Blocked by #N`. Don't over-declare blockers — only real ones.
- **Refactor mode** — when the parent is a refactor (e.g. from `improve`), treat each slice as a Martin Fowler micro-step: the smallest change that leaves the program working and green. Sequence them so the codebase is shippable and tests pass after *every* slice — prefer many tiny behaviour-preserving slices over a few big ones, even more so than for feature work.

## 4. Quiz the user once

Present the breakdown as a numbered list. For each slice show: title, size, and blocked-by (if any). Ask:

- Does the granularity feel right? (too coarse / too fine)
- Is the sequence + the blockers correct?
- Any XL still hiding? Should anything be merged or split further?

Iterate until the user approves.

## 5. Publish and link

Make sure the size labels exist (run `init` if not). Then, in sequence order (publish blockers before the slices they block, so `Blocked by #N` references real numbers):

1. Create the issue and capture its number:

   ```
   url=$(gh issue create --title "<title>" --body "<body>" --label "size:<S|M|L>")
   # the trailing path segment of $url is the issue number
   ```

2. Link it under the epic as a sub-issue (GraphQL, using node ids):

   ```
   parent=$(gh issue view <epic#> --json id -q .id)
   child=$(gh issue view <child#> --json id -q .id)
   gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' -f p="$parent" -f c="$child"
   ```

This makes the parent's native progress bar track these slices automatically.

## Sub-issue template (keep it to ~6 lines)

```
## What

<1-3 sentences — the end-to-end slice. Describe behavior, not a layer-by-layer breakdown.>

## Acceptance

- [ ] <binary criterion>
- [ ] ...

Parent #<parent> · Size: <S|M|L>
Blocked by #<n>
```

- Omit the `Blocked by` line entirely if nothing blocks the slice.
- No file paths or code (exception: a decision-encoding snippet, trimmed to the decision).
- Do NOT modify the epic body.

Next: run `board <epic#>` to see progress, or `ship` to start a slice.
