---
name: to-task
description: Capture a single small piece of work as one GitHub issue — concise body, size label, no decomposition. Standalone by default; pass an epic number (or say "add this to #N") to attach it as a native sub-issue of an existing epic instead — the late-addition path, without a full re-decomposition. Use when the work is one vertical slice that doesn't warrant an epic + sub-issues, then ship it directly.
disable-model-invocation: true
---

# workstream: to-task

For work small enough to be ONE vertical slice — no decomposition. Produces a single issue you can `ship` directly, either standalone or as one more slice under an existing epic.

## When to use

- The work is a single, demoable end-to-end slice (roughly **S or M**).
- If it feels **L across several concerns, or XL**, stop — it wants an epic: use `to-epic` then `to-subissues` instead.
- If you only discover it's too big at execution time, don't worry: `ship` gauges complexity and will advise splitting the task into sub-issues (the task itself becomes their parent).
- **One more slice for an epic that's already decomposed?** Don't re-run `to-subissues` for one addition — pass the epic number: `to-task <epic#>`. This is the canonical path any time a sub-issue needs to appear after the epic was already sliced (a "add this to #143" ask, or `promote` filing something that belongs under an existing epic).

## Process

1. If you haven't explored the repo, do so. Use the `## Glossary` vocabulary; respect ADRs in `docs/adr/`.
2. Resolve the parent: take an epic number from `$ARGUMENTS` if one is given (or if the user names one in conversation, e.g. "add this to #143"). No argument → standalone task, no parent.
3. Synthesize the task from the conversation — **do not interview** (that's `grill`'s job). Flag any load-bearing assumption. If there's a parent, note whether this slice is genuinely blocked by any of its existing sub-issues — don't over-declare.
4. Draft the issue with the concise template below; size it S/M/L.
5. Show the draft. On approval, publish:

   ```
   url=$(gh issue create --title "<title>" --body "<body>" --label "size:<S|M|L>")
   ```

   Standalone: no `epic` label, no parent — done, report the issue number/URL.

   **Attaching to a parent — the two-line tail, always, not optionally:**

   ```
   parent=$(gh issue view <epic#> --json id -q .id)
   child=$(gh issue view <child#> --json id -q .id)
   gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' -f p="$parent" -f c="$child"
   ```

   Then, if the body declared a `Blocked by #N`, record it as a native edge too — the same call `to-subissues` uses:

   ```
   blocker_id=$(gh api repos/<owner>/<repo>/issues/<N> --jq .id)
   gh api --method POST repos/<owner>/<repo>/issues/<child#>/dependencies/blocked_by -F issue_id="$blocker_id"
   ```

   Skipping either call is exactly how a sub-issue ends up graph-invisible — this tail isn't optional just because it's one issue, not a whole decomposition.

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
- **Attaching to a parent?** Add `Parent #<epic>` next to `Size`, and a `Blocked by #<n>` line if genuinely blocked — same shape as a `to-subissues` slice. Standalone tasks omit both.

Next: run `ship <#>` to implement it.
