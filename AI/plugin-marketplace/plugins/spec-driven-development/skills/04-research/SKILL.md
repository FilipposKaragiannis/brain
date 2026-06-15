---
description: Analyze task complexity by reading actual source code
---

You are executing Phase 4 of the Spec-Driven Development (SDD) workflow: Research & Complexity Analysis.

Your job is to analyze each task for complexity, unknowns, and risks, then update the tasks file with your findings.

## Step 1: Resolve the Feature

Arguments provided by the user: $ARGUMENTS

Follow this resolution order. **To scan `.specs/`**, use the **Read tool** on the `.specs/` directory — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`) to list directories. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

1. If `$ARGUMENTS` contains a feature slug (any non-flag word), use it. The feature lives at `.specs/<slug>/` with files `prd-<slug>.md` and `tasks-<slug>.json`.
2. If `$ARGUMENTS` is empty or only contains flags, scan `.specs/` using the Read tool. If exactly one feature folder exists, auto-select it. If multiple exist, list them and ask the user to pick one. Stop and wait for their answer.
3. If no `.specs/` directory or no feature folders exist, tell the user and stop.

Check whether `$ARGUMENTS` contains the flag `--force`. If it does, you will rescore ALL tasks, not just those with `complexity: null`.

## Step 2: Read Inputs

- Read the tasks file at `.specs/<slug>/tasks-<slug>.json`. The structure is `{ "feature": "<slug>", "prd": "prd-<slug>.md", "tasks": [...] }`.
- Read the PRD at `.specs/<slug>/prd-<slug>.md`.

## Step 3: Analyze Each Task

Identify which tasks to process:
- Default: only tasks where `complexity` is `null` or missing.
- If `--force` flag is present: all tasks.

For each task to process:

1. Read the task's description, dependencies, and any referenced files or code paths mentioned in the task or the PRD.
2. **Read actual source code** in this repository that the task references or would touch. Do not guess about code structure — open and read the files. If files do not exist yet, note that.
3. Assess complexity on a 1-10 scale using these factors:
   - **Lines of code** likely needed (1 = trivial ~10 lines, 10 = massive ~500+ lines)
   - **Files touched** (1 = single file, 10 = 10+ files across multiple modules)
   - **Integration points** with existing code (APIs, shared state, databases)
   - **Ambiguity** in requirements (are acceptance criteria clear and complete?)
   - **Risk of side effects** (could this break existing functionality?)
4. Identify specific **unknowns** — things that are not answered by the PRD or existing code and need investigation.
5. Identify specific **risks** — things that could go wrong during implementation.

## Step 4: Update the Tasks File

For each analyzed task, update these fields in the tasks JSON:
- `complexity` — integer from 1 to 10
- `complexity_rationale` — one or two sentences explaining the score
- `risks` — array of short risk strings (e.g., `["Breaking change to public API", "No existing test coverage"]`)
- `unknowns` — array of short unknown strings (e.g., `["Unclear how auth tokens are refreshed", "No docs for third-party webhook format"]`)

Write the updated JSON back to the tasks file. Preserve all other fields. Use 2-space indentation.

## Step 5: Print Summary Table

Print a markdown table with columns: ID, Title, Complexity, Risks. Example:

```
| ID | Title                    | Cx | Risks                          |
|----|--------------------------|---:|--------------------------------|
|  1 | Set up auth middleware   |  3 | None                           |
|  2 | Integrate payment API    |  7 | No sandbox env, rate limits    |
|  3 | Build admin dashboard    |  9 | Unclear scope, many components |
```

## Step 6: Flag High-Complexity Tasks

For any task scoring 8 or higher:
- Flag it clearly as **"Needs decomposition"**.
- Suggest a concrete way to split it into smaller tasks (2-4 subtasks), with a brief rationale.

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

## Step 8: Next Step

Tell the user:

> Research complete. Run `/sdd-5-refine` to check task readiness and identify blockers.

## Rules

- **Read actual code.** Never assume what a file contains. Open it and read it.
- **Complexity is relative to this codebase's patterns.** A task that follows existing patterns is less complex than one that introduces new patterns.
- **Unknowns increase complexity.** If you cannot determine something from reading the code and PRD, that is an unknown, and it should push the complexity score up.
- **Be specific.** Vague risks like "might be hard" are useless. Name the specific concern.
- **Preserve existing data.** Do not overwrite fields you are not updating (e.g., `status`, `ready`, `dependencies`).
