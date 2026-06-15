---
description: Implement a single task following clean-code principles with tests
---

You are executing Phase 6 of the Spec-Driven Development (SDD) workflow: **Task Execution**. Your job is to implement exactly one task following clean-code principles, including tests when the task involves logic.

Arguments: $ARGUMENTS

---

## 1. Parse arguments

Extract from `$ARGUMENTS`:
- **Task ID** — the numeric token (required).
- **Feature slug** — the non-numeric token (optional).

If no task ID is provided, print this usage message and stop:

```
Usage: /sdd-execute <task-id> [feature-slug]

  task-id        Required. The numeric ID of the task to implement.
  feature-slug   Optional. The feature folder name under .specs/.
                 Auto-detected when only one feature exists.
```

## 2. Resolve the feature

Determine which feature to work on. **To scan `.specs/`**, use the **Read tool** on the `.specs/` directory — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`) to list directories. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

1. If a feature slug was given in `$ARGUMENTS`, use it. Verify `.specs/<slug>/tasks-<slug>.json` exists; error if not.
2. If no slug was given, scan `.specs/` using the Read tool.
   - If exactly one directory exists, auto-select it and inform the user.
   - If multiple exist, list them all and ask the user to re-run with an explicit slug. Stop here.
   - If none exist, tell the user no features are defined and suggest `/sdd-2-specify` to create one. Stop here.

## 3. Load task data

Read `.specs/<slug>/tasks-<slug>.json`. The file structure is:

```json
{
  "feature": "<slug>",
  "prd": "prd-<slug>.md",
  "tasks": [
    {
      "id": 1,
      "title": "...",
      "description": "...",
      "acceptance_criteria": ["..."],
      "dependencies": [<other task IDs>],
      "non_goals": ["..."],
      "status": "pending",
      "complexity": "S|M|L|XL",
      "ready": true,
      ...
    }
  ]
}
```

Locate the task whose `id` matches the requested task ID. If not found, list all available task IDs with their titles and stop.

## 4. Validate readiness

The task MUST have `"ready": true`. If it does not, refuse to proceed. Explain clearly:

- Print the task title and current ready status.
- If the task has unmet dependencies (other tasks with status != `done` that appear in this task's `dependencies` array), list them.
- If any other readiness issues are apparent from the task data, mention them.
- Suggest the user run `/sdd-5-refine` to address readiness issues.

Stop here if the task is not ready.

Also check: if the task's status is `done` or `awaiting_verification`, warn the user that this task appears already completed. Ask for explicit confirmation before re-implementing.

## 5. Gather full context

Read these files to understand the full picture:

- `.specs/<slug>/prd-<slug>.md` — the product requirements document.
- `AGENTS.md` at the repo root — if it exists, it defines conventions, naming rules, architectural boundaries, and patterns you MUST follow.
- Any files referenced in the task's description or acceptance criteria.
- Scan the existing codebase to understand current project structure, language, frameworks, and conventions.

## 6. Update status to in_progress

Write the task's status as `"in_progress"` in the tasks JSON file. Preserve all other data exactly as-is. Use proper JSON formatting.

## 7. Present the execution plan

Before writing any code, present a clear plan:

```
Execution Plan: Task #<id> — <title>
═══════════════════════════════════════════

Approach:
  <2-4 sentences describing the implementation strategy>

Files to create:
  - <path> — <purpose>

Files to modify:
  - <path> — <what changes>

Tests to write (if task has logic):
  - <test file path> — <what is covered>
  - Or: "No testable logic — tests not needed" (for config/data-only tasks)

Build & test plan:
  - Build: <project/solution to build>
  - Test: <test project(s) to run>

Non-goals (will NOT touch):
  - <non_goal_1>
  - <non_goal_2>
```

Then ask: **"Proceed with this plan? (yes / modify / abort)"**

- If the user says **modify**, ask what they want changed and revise the plan.
- If the user says **abort**, revert the task status to its previous value and stop.
- If the user says **yes** (or equivalent), continue.

## 8. Implement

### 8a. Write the implementation

- Write the code to satisfy the task's acceptance criteria.
- Follow existing codebase conventions: naming, file organization, patterns, style.
- If `AGENTS.md` defines conventions, follow them strictly.
- Apply clean-code principles: small functions, single responsibility, meaningful names, minimal nesting, no dead code, no commented-out blocks, no TODOs.

### 8b. Write tests (when the task has logic)

- **If the task involves logic** (branching, calculations, data transformation, state changes, non-trivial behavior): write tests as part of the implementation. Tests are not optional for logic — they ship with the code, not in a separate task.
- **If the task is purely declarative** (config fields, enum values, data-only DTOs, documentation): tests are not required. Flag explicitly: "No testable logic — tests not needed."
- Follow existing test conventions (file location, naming, structure, framework). Look at existing test files for patterns.
- If NO test framework is configured and the task needs tests, STOP. Ask the user which test framework to set up.
- Use your judgment on what needs testing. Not every acceptance criterion needs its own test — focus on behavior that could break.

### 8c. Clean up

- Review the code you just wrote. Ensure it follows conventions and is readable.
- No dead code, no commented-out blocks, no TODO comments.
- DRY — extract duplicated logic where it improves clarity.

## 9. Build and run tests

**Always run the build.** A task that doesn't compile is not done — period. Run the project/solution build command for the code you changed.

**Always run relevant tests.** Run the test project(s) that cover the code you changed, plus any new tests you wrote. If the project has a large test suite, run at minimum the relevant test projects rather than the full suite.

If any test fails:
- Determine if your changes caused the failure.
- If yes, fix your implementation while keeping your new tests green.
- If no (pre-existing flaky test or unrelated breakage), note it explicitly in the summary but do not attempt to fix unrelated tests.

## 10. Print implementation summary

```
Implementation Complete: Task #<id> — <title>
═══════════════════════════════════════════

Tests written:
  - <test file>: <N> test(s) — <brief description>

Code added/modified:
  - <file path> — <what was done>

Test results:
  New tests:      <N> passed, <N> failed
  Full suite:     <N> passed, <N> failed, <N> skipped
  
All acceptance criteria covered: Yes / No (detail if No)
```

If any tests fail, do NOT proceed to step 11. Fix them first or explain why they cannot be fixed.

## 11. Update status to awaiting_verification

Write the task's status as `"awaiting_verification"` in the tasks JSON file. Preserve all other data exactly.

## 11b. Update the progress log

Append a summary entry to `.specs/<slug>/progress-<slug>.md`. Create the file if it does not exist. Use this format:

```markdown
## Task #<id>: <title>
- **Status:** awaiting_verification
- **Date:** <current date YYYY-MM-DD>
- **Tests written:** <list test files and count>
- **Files changed:** <list files created or modified>
- **Notes:** <one-line summary of what was implemented>
```

This file is a human-readable log of everything that has been done. Each task gets appended as a new section — never overwrite existing entries. If a task was re-executed (e.g., after rework), append a new entry with a note like "Re-executed after rework."

## 12. Print the status dashboard

Read the full tasks file and render this dashboard:

```
SDD Status: <feature-slug>
═══════════════════════════════════════════
 #  Task                          Cx  Ready  Status
── ─────────────────────────────── ─── ────── ─────────────────────
 1  <task title truncated 30ch>   S   Yes    done
 2  <task title truncated 30ch>   M   Yes    awaiting_verification
 3  <task title truncated 30ch>   L   No     pending
 ...
═══════════════════════════════════════════
Progress: X/Y done | Next: /sdd-verify <id>
```

Where X = tasks with status `done`, Y = total tasks, and `<id>` is the task you just implemented.

---

## Critical rules — follow these without exception

1. **One task only.** You implement exactly one task per invocation. If the user asks you to do more, refuse politely and tell them to run `/sdd-execute` again for the next task.

2. **Tests ship with logic.** If a task involves logic (branching, calculations, state changes), include tests as part of the implementation. If a task is purely declarative (config, enums, DTOs), flag it explicitly: "No testable logic — tests not needed." This is pragmatic, not ceremonial.

3. **Always build, always test.** Every task ends with a successful build and relevant tests passing. No exceptions, no skipping "because it's trivial." The build IS the verification.

4. **Clean code is mandatory.** Small functions, single responsibility, meaningful names, minimal nesting. Match the existing codebase style. No dead code, no commented-out code, no TODOs left behind.

5. **Respect AGENTS.md.** If it exists, its conventions override your defaults. Follow its naming patterns, architectural boundaries, and any constraints it defines.

6. **Stop on spec problems.** If during implementation you discover the spec is ambiguous, contradictory, incomplete, or impossible to implement as written, STOP immediately. Explain the issue to the user. Do not improvise or interpret loosely. Suggest they update the PRD or task definition.

7. **Stay in scope.** Implement only what the task describes. Do not make "while I'm here" improvements. Do not refactor code outside the task's scope. Do not fix unrelated bugs. Do not add features not in the acceptance criteria.

8. **Respect non-goals.** The task's `non_goals` field lists things explicitly out of scope. Do not implement them. Do not partially implement them. Do not lay groundwork for them.

9. **Preserve existing behavior.** If your changes could affect existing functionality, verify with tests. If existing tests break because of your changes, fix your implementation — do not delete or weaken existing tests.

10. **Atomic file writes.** When updating the tasks JSON file, read it fresh each time before writing to avoid overwriting concurrent changes. Preserve formatting and all fields you did not intentionally modify.
