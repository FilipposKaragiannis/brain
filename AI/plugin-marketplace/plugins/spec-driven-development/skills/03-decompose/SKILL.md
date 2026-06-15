---
description: Break a PRD into independently executable tasks
---

Decompose a PRD into independently executable tasks. This is Phase 3 of the Spec-Driven Development workflow.

## Step 1: Resolve the feature

Determine which feature to work on. **To scan `.specs/`**, use the **Read tool** on the `.specs/` directory — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`) to list directories. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

1. If `$ARGUMENTS` contains a feature slug, use that slug.
2. If `$ARGUMENTS` is empty and only one folder exists under `.specs/`, use it automatically.
3. If `$ARGUMENTS` is empty and multiple folders exist under `.specs/`, list them all and ask the user to pick one. Do not proceed until the user responds.

The resolved slug is referred to as `<slug>` below. The feature folder is `.specs/<slug>/`.

## Step 2: Read the PRD

Read the file `.specs/<slug>/prd-<slug>.md` in full. If the file does not exist, tell the user and stop.

## Step 3: Decompose into tasks

Analyze the PRD and break the work into discrete, implementable tasks. Apply these rules strictly:

- **Target 3-10 tasks.** Fewer than 3 means the PRD scope is too small for decomposition. More than 10 means the PRD likely covers multiple features and should be split first. If either case applies, tell the user and stop.
- **Order tasks by dependency.** Task N may only depend on tasks with IDs lower than N. The first tasks should have no dependencies.
- **Each task must have:**
  - A clear, specific title (short phrase, not a sentence).
  - A one-paragraph description explaining what the task does, what it takes as input, and what it produces as output.
  - Concrete acceptance criteria (testable statements, not vague goals).
  - Explicit non-goals stating what this task should NOT do, to prevent scope creep.
  - A `dependencies` array listing the IDs of tasks that must be completed before this one can start. Use an empty array if there are none.
- **No hidden dependencies.** If task B needs the output of task A, that dependency must be declared.
- **Ambiguity handling.** If the PRD is ambiguous on any point that affects how you decompose or scope a task, flag it to the user as a question rather than guessing. List all ambiguities together before writing the tasks file so the user can resolve them in one pass.

## Step 4: Write the tasks file

For each task, produce this JSON structure:

```json
{
  "id": 1,
  "title": "Short descriptive title",
  "description": "One paragraph explaining what this task does, its inputs, and its outputs.",
  "acceptance_criteria": ["criterion 1", "criterion 2"],
  "dependencies": [],
  "non_goals": ["what this task should NOT do"],
  "status": "pending",
  "complexity": null,
  "ready": false
}
```

Wrap the full task array in this envelope and write it to `.specs/<slug>/tasks-<slug>.json`:

```json
{
  "feature": "<slug>",
  "prd": "prd-<slug>.md",
  "tasks": [
    // task objects here
  ]
}
```

If the file already exists, warn the user that it will be overwritten and proceed.

## Step 5: Print a summary

After writing the file, print a Markdown table with these columns:

| ID | Title | Dependencies |
|----|-------|--------------|

List every task in order. For the Dependencies column, show the IDs as a comma-separated list, or "none" if the array is empty.

## Step 6: Next step

Tell the user:

> Tasks written to `.specs/<slug>/tasks-<slug>.json`. Run `/sdd-4-research` next to analyze task complexity and identify implementation approaches.
