---
name: to-subissues
description: Break a parent issue — an epic, or a task that grew too big — into concise, independently-shippable vertical-slice sub-issues on GitHub, each size-tagged (S/M/L), optionally blocked-by another, and linked under the parent so progress rolls up natively. Assigns every epic acceptance line to a slice or a dedicated verification-closeout slice, and flags merge-order contention between parallel slices. Use after to-epic, or when ship advises a split.
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
- **Wide refactor (a different case from refactor mode above)** — a single mechanical change (rename a column, retype a shared symbol) whose **blast radius** fans across the whole codebase, breaking many call sites at once so no vertical slice — and no Fowler micro-step — can land green on its own. Don't force it into either shape; sequence it as **expand–contract** instead:
  1. **Expand** — add the new form beside the old, so nothing breaks. One slice.
  2. **Migrate** — move call sites over in batches sized by blast radius (per package, per directory). Each batch is its own slice, `Blocked by` the expand slice. CI stays green batch to batch because the old form still exists alongside the new one.
  3. **Contract** — delete the old form once no caller remains. One slice, `Blocked by` every migrate batch.

  If even a single batch can't land green alone, keep the sequence but let the migrate batches share an integration branch that all block a final integrate-and-verify slice — green is promised only there, not batch by batch.

- **Contention** — two slices can be independent in *dependency* terms (neither blocks the other, both can be written in parallel) but not in *merge* terms: they touch a shared seam and landing them out of order, or attributing an effect to the wrong one, causes real damage. Three shapes to watch for: an **append-order seam** (e.g. an enum/fixture table indexed by ordinal — parallel writers, but must merge in a fixed order); a **shared behavioural golden** (multiple slices shift the same measured baseline, so landing them together makes it impossible to attribute a change to a cause); or a **vocabulary collision** (two slices independently reuse the same term for different concepts — see step 5). When you spot one, note it on both slices — don't over-declare, only real seam contention.

## 4. Assign every epic acceptance line

Fetch the parent's `## Acceptance` list (already in hand from step 1). For **every** line in it, decide:

- **(a) Owned by a named slice** — record which slice (by draft title) satisfies it. Most feature-level acceptance lines land here.
- **(b) Cross-cutting** — no single slice owns it. This is common for promises like "identical output across N conditions," "zero-allocation," "works cross-platform," or a manual sign-off — properties only checkable once the relevant slices all exist.

For every **(b)** line, draft an explicit **verification-closeout slice**: title it `Verify: <the promise>`, give it its own `## Acceptance` line rephrasing the epic promise as a binary, evidence-backed check (cite the test/harness that will prove it — code, never docs or an agent's say-so), and `Blocked by` every slice whose landing it depends on to be checkable.

**Do not finish this skill with an unassigned epic acceptance line.** If a line doesn't cleanly fit (a) or (b), that's a signal the epic itself is underspecified — flag it to the user rather than silently dropping it.

## 5. Check for vocabulary collisions

Before quizzing the user, diff every domain noun the new slices introduce — in titles and bodies — against each other and against `## Glossary` in `CLAUDE.md`. Two slice bodies can each read correctly in isolation and still poison the glossary together if they silently reuse a term for two different concepts (e.g. one slice's "persona" means an opponent play-style, another's means a restraint profile). Flag any collision found; propose a rename for one side before publishing, or a glossary disambiguation if both meanings are legitimate and need distinct terms.

## 6. Quiz the user once

Present the breakdown as a numbered list. For each slice show: title, size, blocked-by (if any), and contends-with (if any). Also show the epic-acceptance ownership map from step 4 (which slice owns which line, and the verification-closeout slice(s) for cross-cutting lines) and any vocabulary flags from step 5. Ask:

- Does the granularity feel right? (too coarse / too fine)
- Is the sequence + the blockers correct?
- Any XL still hiding? Should anything be merged or split further?
- Does the acceptance-ownership map look right — anything mis-assigned?

Iterate until the user approves.

## 7. Publish and link

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

3. If this slice has a `Blocked by #N`, record it as a native GitHub issue dependency (not just body text) so the frontier is queryable without opening bodies:

   ```
   blocker_id=$(gh api repos/<owner>/<repo>/issues/<N> --jq .id)   # database id, not #number or node_id
   gh api --method POST repos/<owner>/<repo>/issues/<child#>/dependencies/blocked_by -F issue_id="$blocker_id"
   ```

   Still write the `Blocked by #<n>` line in the body too (below) — it's the human-readable copy; the API call is what makes it a real, queryable edge.

   `Contends with` has no native GitHub equivalent (it doesn't gate start order, only merge order) — it stays prose-only in the body.

4. **Once every slice in this run is published and linked, validate the whole graph — don't just trust each write succeeded.** Run the builder (see [dependency-graph.md](../_shared/dependency-graph.md) for how to locate and invoke it correctly — the target repo's working directory isn't the plugin's own directory).

   For every slice, cross-check its prose `Blocked by #N` line against that node's `blockers` array in the JSON. **If any prose-declared blocker has no matching native edge, this is a hard failure, not a warning** — retry the `dependencies/blocked_by` POST for the missing edge and re-run the check before reporting this skill as done. This is the exact drift that left an older cohort of sub-issues with prose blockers and zero native edges — verifying the graph structurally, instead of assuming an API call that returned 2xx actually landed, is what closes that gap for good.

## Sub-issue template (keep it to ~6 lines)

```
## What

<1-3 sentences — the end-to-end slice. Describe behavior, not a layer-by-layer breakdown.>

## Acceptance

- [ ] <binary criterion>
- [ ] ...

Parent #<parent> · Size: <S|M|L>
Blocked by #<n>
Contends with #<n> (shared: <seam>)
```

- Omit the `Blocked by` line entirely if nothing blocks the slice; omit `Contends with` entirely unless step 3 found a real seam collision.
- A verification-closeout slice (from step 4) uses the same template — its `## What` is the cross-cutting promise it verifies, its `## Acceptance` is the evidence-backed binary check, and it is always `Blocked by` every slice it verifies.
- No file paths or code (exception: a decision-encoding snippet, trimmed to the decision).
- Do NOT modify the epic body.

Next: run `board <epic#>` to see progress, or `ship` to start a slice.
