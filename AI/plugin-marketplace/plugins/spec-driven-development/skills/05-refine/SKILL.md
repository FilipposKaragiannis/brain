---
name: 05-refine
description: Validate task readiness and auto-split complex tasks
---

You are executing Phase 5 of the Spec-Driven Development (SDD) workflow: Readiness Refinement.

Your job is to evaluate each task against a readiness checklist, mark tasks as ready or not, report blockers, and suggest next actions.

## Step 1: Resolve the Feature

Arguments provided by the user: $ARGUMENTS

Follow this resolution order. **To scan `.specs/`**, use the **Read tool** on the `.specs/` directory — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`) to list directories. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

1. If `$ARGUMENTS` contains a feature slug (any non-flag word), use it. The feature lives at `.specs/<slug>/` with files `prd-<slug>.md` and `tasks-<slug>.json`.
2. If `$ARGUMENTS` is empty, scan `.specs/` using the Read tool. If exactly one feature folder exists, auto-select it. If multiple exist, list them and ask the user to pick one. Stop and wait for their answer.
3. If no `.specs/` directory or no feature folders exist, tell the user and stop.

## Step 2: Read Inputs

- Read the tasks file at `.specs/<slug>/tasks-<slug>.json`. The structure is `{ "feature": "<slug>", "prd": "prd-<slug>.md", "tasks": [...] }`.
- Read the PRD at `.specs/<slug>/prd-<slug>.md` for reference on acceptance criteria and scope.

## Step 3: Evaluate Each Task

Process every task where `ready` is `false` (or missing). Tasks already marked `ready: true` are skipped unless their dependencies have changed — if any dependency has had its status reverted from `done`, re-evaluate the dependent task.

For each task, evaluate ALL of the following checks:

### Readiness Checklist

1. **Low or medium complexity (1-6).** If the task's `complexity` score is 7 or higher, this check FAILS — the task will be automatically decomposed in Step 8. If `complexity` is `null` or missing, this check FAILS — tell the user to run `/sdd-4-research` first.

2. **Spec exists with acceptance criteria.** The task must have a description and clear acceptance criteria (either in the task itself or in the PRD section it references). If acceptance criteria are vague or missing, this check FAILS.

3. **Dependencies resolved.** All tasks listed in this task's `dependencies` array must have `status: "done"`. Not just `ready` — actually `done`. If the task has no dependencies, this check PASSES. If any dependency is not `done`, this check FAILS. List which dependencies are blocking.

4. **Context available.** Any source files, APIs, or modules referenced by the task or its PRD section must exist and be accessible. Read the referenced files to confirm they exist. If a file is referenced but does not exist and is not created by a predecessor task that is `done`, this check FAILS.

5. **Scope bounded.** The task must have clear boundaries — it should be obvious what is NOT included. If the task description is open-ended or lacks non-goals, this check FAILS.

6. **Verification defined.** The acceptance criteria must be testable. There must be a concrete way to verify the task is complete (e.g., a test to write, a behavior to observe, a command to run). If the criteria are subjective or unmeasurable, this check FAILS.

## Step 4: Update the Tasks File

For each evaluated task:

- If ALL 6 checks pass: set `ready: true`.
- If ANY check fails: keep `ready: false` (or set it to `false` if it was missing).
- Add or update a `readiness_issues` field — an array of strings describing which checks failed and why. If the task is ready, set this to an empty array `[]`.

Write the updated JSON back to the tasks file. Preserve all other fields. Use 2-space indentation.

## Step 5: Print Readiness Report

For each task that is NOT ready, print a clear report:

```
Task #<id>: <title>
  [FAIL] Low complexity: score is 8, recommend splitting
  [PASS] Spec exists
  [FAIL] Dependencies resolved: #3 is still "pending"
  [PASS] Context available
  [PASS] Scope bounded
  [FAIL] Verification defined: no testable acceptance criteria
  Suggested fix: Add unit test expectations to acceptance criteria; wait for #3.
```

For each task that IS ready, print a brief confirmation:

```
Task #<id>: <title> -> READY
```

## Step 6: Print Summary

Print counts:

```
Ready: X tasks | Blocked: Y tasks | Total: Z tasks
Blocking reasons: <most common reasons across all blocked tasks>
```

## Step 7: Print the Dashboard

Print the SDD dashboard in this exact format:

```
SDD Status: <feature-slug>
═══════════════════════════════════════════
 #  Task                        Cx  Ready  Status
 1  Some task name               3  yes    done
 2  Another task                  5  no     pending (blocked: #1)
═══════════════════════════════════════════
Progress: X/Y done | Next: <next actionable task or "none">
```

- `Cx` = complexity score (or `-` if not yet scored).
- `Ready` = `yes` or `no` based on the task's `ready` field.
- `Status` = the task's `status` field. If the task has unresolved dependencies, append `(blocked: #<dep_id>, ...)`.
- `Progress` line: count of tasks with status `done` vs total. `Next` = first task that is `ready: true` and not `done`.

## Step 8: Decompose High-Complexity Tasks

This step runs automatically — no user confirmation needed.

For every task with complexity 7 or higher:

1. Read the PRD, the original task's description, acceptance criteria, non-goals, and the `complexity_rationale` from the research phase. Use the rationale to understand **why** the task is complex — this guides how to split it.
2. Break the task into **2-4 smaller subtasks**. Each subtask should target complexity 6 or below. Use the complexity factors identified during research (e.g., multiple files touched, integration points, ambiguity) to find natural seam lines for splitting.
3. Each subtask gets:
   - A new ID (next available integer after the current highest ID in the tasks array).
   - A clear title, description, acceptance criteria, non-goals, and dependencies — same structure as any other task.
   - `"status": "pending"`, `"complexity": null`, `"ready": false`.
4. The subtasks inherit the original task's dependencies. If the subtasks must be done in sequence, each depends on the previous one.
5. **Rewire downstream dependencies:** any task that depended on the original task now depends on **all** of the new subtasks (or just the last one if they are sequential).
6. Set the original task's `"status"` to `"decomposed"`. It will no longer be picked up by execute or next.

After processing all high-complexity tasks:

7. Write the updated JSON back to the tasks file. Preserve all other fields. Use 2-space indentation.
8. Print a summary of every decomposition:

```
Decomposed task #<id> "<title>" (complexity <score>) into:
  #<new_id> <new_title>
  #<new_id> <new_title>
  Reason: <brief explanation of the seam line used, derived from complexity_rationale>
Dependencies updated: #<downstream_id> now depends on [#<new_ids>]
```

9. Re-run the readiness evaluation (Step 3) on the newly created subtasks only, update the tasks file, and reprint the dashboard.

If no tasks have complexity 7+, skip this step entirely.

## Step 9: Suggest Next Action

Based on the results:

- If there are ready tasks: suggest `/sdd-next` or `/sdd-execute <id>` for the first ready task (lowest ID that is `ready: true` and not `done`).
- If no tasks are ready because of missing complexity scores: suggest `/sdd-4-research`.
- If no tasks are ready because of unresolved dependencies: identify the blocking chain and suggest which task to complete first.

## Rules

- **A task with complexity 7+ is NEVER ready.** No exceptions. It must be decomposed into smaller tasks first.
- **"Dependencies resolved" means upstream tasks are `done`**, not just `ready`. A task cannot start until its dependencies are finished.
- **This command is idempotent.** It is safe to re-run after making changes. It will re-evaluate all non-ready tasks and update their status accordingly.
- **Read actual code when checking context availability.** Do not assume files exist — verify by reading them.
- **Be actionable in your suggestions.** Do not say "fix the issues." Say exactly what to do: "Add acceptance criteria specifying the expected HTTP status codes and response body format."
- **Preserve existing data.** Do not overwrite fields you are not updating (e.g., `complexity`, `status`, `complexity_rationale`).
