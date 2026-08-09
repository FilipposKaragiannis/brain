---
name: board
description: Progress dashboard for an epic — the native sub-issue rollup plus each slice's state, size, and ready/blocked status. Also checks the data it already has for drift (prose Blocked-by vs. native dependency edges, closed issues still labeled status:in-review, open issues whose merged PR didn't auto-close) and offers a confirmed fix only when it finds something — nothing to run separately, nothing prompted on a healthy epic. `--plan` renders an execution plan instead — a wave/blocked-by table plus an SVG dependency graph, both built from scripts/epic_graph.py's JSON model.
---

# workstream: board

Read-only by default — rendering the dashboard never requires a mutation. The one exception: if the data board already fetched reveals drift (a stale dependency edge, a lifecycle label that never got cleaned up), it says so and offers to fix it, but **never mutates without an explicit yes**. On a healthy epic this whole path is silent — you'd never know the check ran.

## 1. Resolve the epic

Take the epic number from `$ARGUMENTS`. If none given, list open epics and ask which:

```
gh issue list --label epic --state open --json number,title
```

If exactly one open epic exists, auto-select it.

## 2. Fetch the data

Get `owner`, `repo`, and the default branch:

```
gh repo view --json owner,name,defaultBranchRef
```

Then fetch every sub-issue, open and closed — closed ones matter here too, for the lifecycle and stale-reference checks in step 4:

```
gh api graphql -f query='
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){
    issue(number:$n){
      title
      subIssues(first:100){ nodes{
        number title state body
        assignees(first:5){ nodes{ login } }
        labels(first:10){ nodes{ name } }
        closedByPullRequestsReferences(first:5){ nodes{ number state baseRefName } }
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

For `todo` / `in progress` slices, compute blocked/ready from the **native dependency graph**, never from the body text — prose `Blocked by #N` lines can drift from reality (renamed, closed, or never-synced blockers) and are for humans reading the issue, not for this computation. Run the builder once and reuse its output for the rest of this run (steps 4 and 7 need the same data):

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/epic_graph.py" <owner>/<repo> <epic#>
```

`${CLAUDE_PLUGIN_ROOT}` can resolve empty inside `SKILL.md`-driven commands (a known Claude Code bug) — if that path doesn't exist, locate the plugin's installed root yourself and retry. See [dependency-graph.md](../_shared/dependency-graph.md) for the full fallback.

Its `nodes` map already resolves this: a node's `blockers` array contains only *open* blockers (closed ones are pre-filtered out), so **blocked** iff `nodes[<n>].blockers` is non-empty, **ready** iff it's empty.

Then compute the epic totals **from these node states** — NOT from `subIssuesSummary`, which is eventually-consistent and lags a few seconds behind a just-made change:

- `done` = sub-issues whose state is `CLOSED`
- `total` = all sub-issues
- `pct` = round(`done` / `total` × 100)
- `in review` = open sub-issues carrying `status:in-review`

## 4. Detect drift

Everything here reads data steps 2–3 already fetched — no extra calls. This is what used to be a separate `doctor` command; folding it in here means it runs every time you'd want it (whenever you're looking at the board) instead of only when you remember to ask.

**Dependency graph — prose vs. native**, for every *open* sub-issue:

- Parse `Blocked by #A, #B` from its `body` (may be absent).
- Compare against that node's native `blockers` in the step-3 JSON.
- **In prose, not native** — the edge was never written (an older-cohort issue, or a `to-subissues` API call that silently failed).
- **In native, not prose** — the edge exists but a human reading the issue body can't see it.
- **Prose names a number that's closed** (check against the full sub-issue list from step 2, not just the open nodes) — inert; the text is just stale.

**Lifecycle drift**, across all sub-issues from step 2:

- **Closed issue still carrying a `status:*` label** — never stripped when it closed.
- **Open issue with a `closedByPullRequestsReferences` entry in state `MERGED`** — its PR merged but the issue didn't auto-close. Near-certain cause: the PR's `baseRefName` isn't `defaultBranchRef` (an integration-branch epic) — squash-merging into a non-default base doesn't trigger GitHub's auto-close even with `Resolves #n` in the PR body.

If none of the above fires, don't mention this step at all — move straight to rendering. Silence on a healthy epic is the point.

## 5. Render the board

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

If step 4 found anything, append it right after the sub-issue list, before the Next line:

```
⚠ Drift found:
  #12 blocked_by #9   prose only  → add native edge
  #15 "Blocked by #7" but #7 is closed → drop from prose
  #10 closed, still labeled status:in-review → strip label
  #13 open, PR #41 merged into epic/foo (not default) → close + strip label
```

End with a Next line (first that applies):

- Ready slices exist → "Next: `ship` (suggests #<lowest-order ready>) or `ship <#>`."
- In-review slices exist (and none ready) → "Awaiting review — merge the open PR(s) to advance the bar."
- None ready but blocked slices remain → "All open slices are blocked — finish their blockers first."
- All sub-issues closed → "Epic complete 🎉 — close the epic if the work is done."
- No sub-issues at all → "No slices yet — run `to-subissues <epic#>`."

If step 4 found drift, follow the Next line with: **"Found N reconciliation issue(s) above — apply them? (all / pick / no)"**

## 6. Fix confirmed drift

Only reachable from the prompt at the end of step 5, and only for the rows the user actually confirmed — never apply a row they didn't select.

- **Prose blocker missing its native edge:**
  ```
  blocker_id=$(gh api repos/<owner>/<repo>/issues/<N> --jq .id)
  gh api --method POST repos/<owner>/<repo>/issues/<child#>/dependencies/blocked_by -F issue_id="$blocker_id"
  ```
- **Native edge missing its prose line:** append/update `Blocked by #N` in the issue body.
- **Prose names a closed issue:** rewrite the `Blocked by` line to drop that reference (remove the line entirely if nothing open remains). Never touch a *native* edge to a closed issue — GitHub already treats it as satisfied.
- **Closed issue still labeled `status:*`:** `gh issue edit <n> --remove-label "status:in-review"`.
- **Open issue whose PR merged but didn't auto-close:** `gh issue close <n> --comment "Closed by merge of #<pr> into <baseRefName>"`, then strip any `status:*` label.

Report what changed. Never retroactively tick an acceptance checkbox or infer "done" as a side effect of any of this — that's a different problem (`ship`'s staleness refresh), and it's not what these fixes touch.

## 7. Execution-plan view (`board <epic#> --plan`)

Step 5 answers "what's the state of each slice." `--plan` answers the different question people actually ask: what can start now, what runs in parallel, and what's the critical path. Same JSON model from step 3 (don't re-run the script) — this is a different cut of it, built on request rather than always, since most checks just want state.

Render **two things from the one model**, in this order — never recompute waves or the critical path by hand here; that logic lives once in `scripts/epic_graph.py` and both renderers below just format its output. Full field-by-field rules are in [dependency-graph.md](../_shared/dependency-graph.md); don't duplicate them here, follow that contract.

**1. A table, in response text.** One row per open node: `#`, title, size, wave (from the model's `waves`), blocked by (the node's `blockers`, empty = `—`). Mark rows on `criticalPath`. Annotate an issue's own state (in flight vs. todo) using step 3's already-computed state, not a separate fetch:

```
#   State  Title                 Size  Wave  Blocked by
12  ○      Add fixture table     S     1     —
14  ⟳      Wire scoring event    M     1     —
15  ○      Verify cross-plat     L     2     #12, #14   ← critical path
```

**2. The SVG, via the visualize widget.** Build it exactly per the shared contract's SVG section, from the same JSON. Hand the widget only the finished SVG — no prose inside that tool call; put explanatory text in your surrounding response, not in the visualization payload. If the current environment has no such widget, fall back to a fenced ` ```svg ` block instead of dropping the visual.

**Contention.** If two nodes in the same wave carry a `Contends with #A, #B (shared: <seam>)` line in their body (written by `to-subissues`), annotate both in the table — "parallel, but serialize the merge — shared `<seam>`" — since the model itself doesn't carry this (it's prose-only, see `to-subissues`).

If there are no open sub-issues, fall through to step 5's "no sub-issues" / "epic complete" messaging instead — nothing to plan.

**Optional: mirror the graph to GitHub.** After rendering, ask: "Also publish this as a Mermaid comment on the epic? (y/n)" — this posts something visible to everyone watching the epic, so it needs the same explicit go-ahead as step 6's fixes, even though it's idempotent. On yes: render Mermaid per the shared contract, find any existing pinned comment (`gh api repos/<owner>/<repo>/issues/<epic#>/comments --jq '.[] | select(.body | contains("<!-- workstream:graph -->")) | .id'`), and either `gh api --method PATCH repos/<owner>/<repo>/issues/comments/<id> -f body=...` to update it or `gh issue comment <epic#> --body "..."` to create it (always include the `<!-- workstream:graph -->` marker so the next run finds it).

## Rules

- Rendering the board (steps 1–5, 7) never mutates anything.
- The only mutations this skill can make are the ones in step 6 (drift fixes) and the optional graph comment in step 7 — both require an explicit, row-level or action-level confirmation first. Never apply a fix or post a comment the user didn't say yes to.
- Never remove a native dependency edge — GitHub already resolves those correctly once the blocker closes; only prose and labels can go stale.
