---
name: board
description: Read-only progress dashboard for an epic — shows the native sub-issue progress rollup plus each slice's state, size, and whether it's ready or blocked. Never modifies anything.
---

# workstream: board

**Strictly read-only.** Never create, modify, close, or label anything.

## 1. Resolve the epic

Take the epic number from `$ARGUMENTS`. If none given, list open epics and ask which:

```
gh issue list --label epic --state open --json number,title
```

If exactly one open epic exists, auto-select it.

## 2. Fetch the data

Get `owner` and `repo` from `gh repo view --json owner,name`, then:

```
gh api graphql -f query='
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){
    issue(number:$n){
      title
      subIssues(first:50){ nodes{
        number title state body
        assignees(first:5){ nodes{ login } }
        labels(first:10){ nodes{ name } }
      }}
    }
  }
}' -f o=<owner> -f r=<repo> -F n=<epic#>
```

## 3. Compute each sub-issue's state

For each sub-issue:

- **done** — the issue is closed (PR merged, or closed directly without a PR).
- **in review** — open and carries the `status:in-review` label (a PR is open; awaiting merge).
- **in progress** — open, no in-review label, but has ≥1 assignee.
- **todo** — open, no in-review label, no assignee.

For `todo` / `in progress` slices, also parse `Blocked by #N` from the `body`: **blocked** if any referenced blocker is still open, otherwise **ready**.

Then compute the epic totals **from these node states** — NOT from `subIssuesSummary`, which is eventually-consistent and lags a few seconds behind a just-made change:

- `done` = sub-issues whose state is `CLOSED`
- `total` = all sub-issues
- `pct` = round(`done` / `total` × 100)
- `in review` = open sub-issues carrying `status:in-review`

## 4. Render the board

```
Epic #<n>  <title>     <bar>  <done>/<total> done (<pct>%)  [· <k> in review]
  <icon> #<n>  <title>          [<size>]  <annotation>
  ...
```

- Icons: `✔` done · `⟳` in review · `◐` in progress · `○` todo.
- `<size>` from the `size:*` label.
- `<annotation>`: `in review` · `in progress` · `ready` · `blocked by #x` (list open blockers) · blank for done.
- Order sub-issues by their order in the `subIssues` connection.
- `<bar>`: 10 blocks filled proportional to the computed `pct` (closed only) — in-review slices are NOT filled until their PR merges. (GitHub's own progress bar on github.com uses `subIssuesSummary` and may lag a few seconds after a change before it self-heals — your computed `pct` is accurate immediately.)

End with a Next line (first that applies):

- Ready slices exist → "Next: `ship` (suggests #<lowest-order ready>) or `ship <#>`."
- In-review slices exist (and none ready) → "Awaiting review — merge the open PR(s) to advance the bar."
- None ready but blocked slices remain → "All open slices are blocked — finish their blockers first."
- All sub-issues closed → "Epic complete 🎉 — close the epic if the work is done."
- No sub-issues at all → "No slices yet — run `to-subissues <epic#>`."
