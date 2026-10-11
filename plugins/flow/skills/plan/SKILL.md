---
name: plan
description: Plan an item to the depth its profile needs. Runs the planning sub-roles in fresh subagents: interviewer (grill), explorer, researcher, architect (design) and planner (plan, epic, tasks), writing their reports under the item's reports directory and the plan into the tracker. Use when the user asks to plan, design, grill, write an epic or decompose an item, or when the next step of an item is grill, epic, tasks, design or plan.
disable-model-invocation: true
---

Plan one item. You orchestrate; the sub-roles do the work in fresh subagents with written
briefs. Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude;
on Codex the path `codex plugin list` prints for `flow`).

## 1. Resolve the item and the step

- Item id from the argument (`gh#310`, `local:task/3`). Read it: `"$P/adapters/<github|local>/read.sh" <id>`.
- Step: the one `next.sh` gave you, else from the state, else by kind: epic → `grill`; task M or
  L → `design`; S or bug → say planning is not in that profile and stop.
- Reports directory: `<worktree or repo root>/.flow/reports/<slug>/` (slug = id with `#`, `:`
  and `/` as dashes). Earlier reports there are inputs; do not redo them.

## 2. Run the step

| step | subagents, in order | writes |
|---|---|---|
| `grill` | interviewer, interactive with the owner | spec in the item; `interview.md` |
| `epic` | planner | epic body in the item; `epic.md` |
| `tasks` | planner, then epic-plan-reviewer on the list | the sub-items (after the decomposition gate) |
| `design` | explorer; researcher only when the exploration or the spec names a question the repo cannot answer; architect | `explore.md`, `research.md`, `design.md` |
| `plan` | planner; epic-plan-reviewer on an L task | `plan.md`; sub-items in tracker-tasks mode |

Spawn each subagent by its roster name with the step brief from `next.sh` when you have one,
else a brief of the same shape: item, step, worktree, reports path, inputs, and the result
file contract (`<reports>/<step>.json` with `status`, `summary`, `size`, `gate`, `message`,
`touches`). Run them one at a time; the architect needs the explorer's report.

The epic-plan-reviewer reads the plan or the task list and returns Blocker, Risk, Gap and
Nice-to-fix findings. Give every Blocker and Gap back to the planner for one more pass; then
stop. Prefer the other provider for the reviewer when both hosts are available.

## 3. The plan template (`plan.md`)

```markdown
# <item id>: <title>
Goal: <one sentence>. Non-goals: <bullets>.
Decomposition: local phases | tracker tasks (<why>)
Size: <S|M|L> (was <size>)

## Phase 1: <title>   independent: no
- [ ] <concrete item>
Touches: src/Sim/**, tests/Sim/**
Verification: <command> → <expected result>

## Phase 2: <title>   independent: yes
...

## Test seams
- <public interface the tests go through>

## Docs to update
- <living doc> when <behaviour> changes

## Risks
- <risk>: <mitigation>
```

Every phase is concrete ("add retry to `PaymentClient.Charge`", not "improve payments"),
has an autonomous verification with an expected result, and names its touches.

## 4. Finish

Write `<reports>/<step>.json` yourself from the last subagent's result when it did not. Say in
one short block what was written where, the size, and whether a gate was raised (interview,
decomposition, plan-approval come from the profile; the orchestrator raises them).
