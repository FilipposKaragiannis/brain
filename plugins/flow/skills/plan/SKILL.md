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
- Reports directory: the one the `next.sh` brief names, else the path
  `"$P/scripts/steward.sh" reports <item>` prints. Earlier reports there are inputs; do not redo them.

## 2. Run the step

| step | subagents, in order | writes |
|---|---|---|
| `grill` | interviewer, interactive with the owner | spec in the item; `interview.md` |
| `epic` | planner | epic body in the item; `epic.md` |
| `tasks` | planner, then epic-plan-reviewer on the list | the sub-items (after the decomposition gate) |
| `design` | explorer; researcher only when the exploration or the spec names a question the repo cannot answer; architect only when the profile turns it on | `explore.md`, `research.md`, `design.md` with the architect |
| `plan` | planner; epic-plan-reviewer on an M or L task | `plan.md`; sub-items in tracker-tasks mode |

Spawn each subagent by its roster name with the step brief from `next.sh` when you have one,
else a brief of the same shape: item, step, worktree, reports path, inputs, and the result
file contract (`<reports>/<step>.json` with `status`, `summary`, `size`, `gate`, `message`,
`touches`; the plan step adds `changes` and, for a conflict, `hold`). Run them one at a time; the
architect needs the explorer's report. The design result carries the exploration's `touches`.

A plan may wait behind other open work: the plan step's brief lists it under `## Other open
work`, the planner checks its final touches with `scripts/hold.sh candidates`, and judges each
item by the rule in [holds.md](holds.md). `advance.sh` writes the hold; the item starts once its
holder closes, with the base merged in first. Only the plan step decides holds: bugs and S tasks
have none.

The architect runs only where its cost pays: L tasks and epics. The brief's `Architect:` line
says yes or no (`next.sh` reads `architect.<profile>` in `$P/profiles.json`; without a brief,
read it there). On no, spawn no architect and write no `design.md`: the design step ends with the
exploration, and the planner designs from `explore.md`.

The epic-plan-reviewer reads the plan or the task list and returns Blocker, Risk, Gap and
Nice-to-fix findings. Give every Blocker and Gap back to the planner for one more pass; then
stop. Prefer the other provider for the reviewer when both hosts are available. It checks the
item's premises too, reading in the tracker each item the plan leans on. A prerequisite that
closed is met when what it promised is in the code. An item the plan expects to do work still
ahead (set a value, own a follow-up) is a Blocker when it is closed or missing: nobody will do
that work. A bug has no plan step; its diagnosis is reviewed in the reproduce step
(`flow:test`).

## 3. The plan template (`plan.md`)

```markdown
# <item id>: <title>
Goal: <one sentence>. Non-goals: <bullets>.
Decomposition: local phases | tracker tasks (<why>)
Size: <S|M|L> (was <size>)

## Acceptance
2. <the item's acceptance line 2, as written>
   Proof: evidence/<name>.png by <the test or replay that captures it>

## Phase 1: <title>   independent: no
- [ ] <concrete item>
Touches: src/Sim/**, tests/Sim/**
Verification: <the command for the tests that cover this phase> → <expected result>

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
has an autonomous verification with an expected result, and names its touches. A verification
runs one test or one group, as the testing guide says how. It is never the project's whole test
command: verify runs that once, scoped to the change.

The `## Acceptance` section holds a named proof for each acceptance line that changes what the
user sees, and for no other line; with none, leave the section out. An entry is the line as the
item writes it, at the start of the line, after its number in the item's order of acceptance
lines (the number the verifier gives it in `proofs.json`), and under it one indented `Proof:`
line naming the file and its capture. The path is relative to the reports folder and stays
under `evidence/`; a clip works the same. The capture is a test or a replay that exists or that
a phase item adds, wired as an `evidence` entry in `.flow/config.yaml` whose `paths` cover the
change. Verify grades a named proof live from its file whatever the verifier wrote, and its
`plan proofs` check fails when the file is missing or empty, so a named file no capture writes
fails verify. A malformed `Proof:` line fails it too: no path or no ` by <capture>`, before any
numbered line, a second one for a line, or a path outside `evidence/`.

## 4. Finish

Write `<reports>/<step>.json` yourself from the last subagent's result when it did not. Say in
one short block what was written where, the size, and whether a gate was raised (interview,
decomposition, plan-approval come from the profile; the orchestrator raises them).
