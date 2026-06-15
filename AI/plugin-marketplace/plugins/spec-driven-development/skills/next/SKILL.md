---
description: Pick the next ready task, execute it, and verify — all in one flow
---

# SDD Next Task

You are executing the `/sdd-next` command. This is the primary developer loop command: it picks the next ready task, executes it, and verifies it against acceptance criteria — all in one flow.

**Arguments received:** $ARGUMENTS

**Supported arguments:**
- `<feature-slug>` — optional, to target a specific feature
- `--commit` — optional, auto-commit after successful verification (local only, never pushes)

---

## Step 1: Resolve the feature

Determine which feature to work on. **To scan `.specs/`**, use the **Read tool** on the `.specs/` directory — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`) to list directories. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

1. If `$ARGUMENTS` contains a non-numeric string, treat it as the feature slug. Look for `.specs/<slug>/tasks-<slug>.json`.
2. If `$ARGUMENTS` is empty, scan `.specs/` using the Read tool.
   - If exactly one feature folder exists, auto-select it.
   - If multiple exist, list each feature with a one-line progress summary (e.g., "3/7 done") and ask the user which one to work on. Stop here until they respond.
3. If no `.specs/` directory or no feature folders exist, tell the user no features have been decomposed yet and suggest running `/sdd-3-decompose`. Stop here.

Once resolved, read the tasks file at `.specs/<slug>/tasks-<slug>.json`. If it does not exist, tell the user and suggest `/sdd-3-decompose`. Stop here.

---

## Step 2: Find the next ready task

Search the tasks array for the first task (by lowest ID) that matches BOTH:
- `ready: true`
- `status: "pending"`

---

## Step 3: Handle the result

### Case A: A ready task was found

Display the task details clearly:

```
Next Task: #<id> — <title>
Complexity: <complexity> — <complexity_rationale>

Description:
  <description>

Acceptance Criteria:
  - [ ] <criterion 1>
  - [ ] <criterion 2>
  ...

Dependencies (all done):
  - #<dep_id> <dep_title> (done)
  ...

Risks:
  - <risk>
  ...
```

Then **ask the user to confirm** before proceeding:

> Ready to execute Task #<id>: "<title>". Proceed? (yes/no)

**Do NOT start execution until the user confirms.** Wait for their response.

### Case B: No ready tasks found

Determine why and suggest the appropriate action. Check these conditions in order:

1. **Tasks with `status: "needs_rework"` exist:**
   List them and suggest re-executing:
   > The following tasks need rework:
   > - #X: <title>
   > Run `/sdd-execute <id>` to re-execute a specific task.

2. **Tasks with `status: "awaiting_verification"` exist:**
   List them and suggest verification:
   > The following tasks are awaiting verification:
   > - #X: <title>
   > Run `/sdd-verify <id>` to verify them.

3. **Tasks with `status: "pending"` and `ready: false` exist (blocked tasks):**
   > Remaining pending tasks are blocked by unfinished dependencies.
   > Run `/sdd-5-refine` to review and unblock them.

4. **All tasks have `status: "done"`:**
   Congratulate the user and print a completion summary:
   ```
   All tasks complete! Feature: <feature-slug>
   ════════════════════════════════════════════
    #  Task                         Status
    1  <title>                      done
    2  <title>                      done
    ...
   ════════════════════════════════════════════
   Total: N tasks completed.
   ```
   Then suggest: "Run `/sdd-review` for a final review of the implementation against the PRD."

5. **No tasks exist at all:**
   > No tasks found. Run `/sdd-3-decompose` to break down the PRD into tasks.

Print the dashboard (see Step 6) and stop here.

---

## Step 4: Execute (on user confirmation)

Once the user confirms, implement the task:

1. Set the task status to `in_progress` in the tasks JSON file.
2. Read the PRD (`prd-<slug>.md`) and `AGENTS.md` (if it exists) for full context.
3. Present the execution plan: what files will be created/modified, what approach will be taken. Wait for user OK.
4. Write the implementation code following existing codebase conventions.
5. **If the task involves logic** (branching, calculations, data transformation, state changes, non-trivial behavior), write tests as part of the task. Tests are not optional for logic — they are part of the implementation, not a separate step.
6. **If the task is purely declarative** (config fields, enum values, data-only DTOs, documentation), tests are not required. Flag explicitly: "No testable logic — tests not needed."
7. Run the project build to confirm compilation succeeds.
8. Run relevant tests (both new and existing) to confirm nothing is broken.
9. Print a summary of changes made (code added/modified, tests written if any, build + test results).

**Execution rules:**
- **Tests are part of the task, not a separate phase.** When a task has logic, write tests alongside the implementation — not before, not after, as part of it. Use your judgment on what needs testing.
- **Clean code.** Small functions, single responsibility, meaningful names, minimal nesting. Follow existing codebase conventions. No dead code, no commented-out blocks, no TODOs.
- **Always build.** Every task must end with a successful build. No exceptions.
- **Always run relevant tests.** Run the test project(s) that cover the code you changed. If no tests exist for the area and the task has no testable logic, note it explicitly.
- **Respect AGENTS.md.** If it exists, follow its conventions for naming, patterns, boundaries.
- **Stop on spec issues.** If implementation reveals the spec is wrong or incomplete, STOP and tell the user rather than improvising.
- **Stay in scope.** Do not modify code outside the task's stated scope. Respect the task's non-goals.
- **Update progress log.** After implementation, append a summary to `.specs/<slug>/progress-<slug>.md` (create if needed). After verification, append the verification result. See the format below.

**Progress log format (append after implementation):**

```markdown
## Task #<id>: <title>
- **Status:** <in_progress | done | needs_rework>
- **Date:** <current date YYYY-MM-DD>
- **Tests written:** <list test files and count>
- **Files changed:** <list files created or modified>
- **Notes:** <one-line summary>
```

**Progress log format (append after verification):**

```markdown
## Verification: Task #<id>: <title>
- **Result:** <PASSED — marked done | FAILED — marked needs_rework>
- **Date:** <current date YYYY-MM-DD>
- **Criteria:** <X/Y passed, Z failed>
- **Failures:** <list failed criteria, or "none">
```

Never overwrite existing entries in the progress log — always append.

---

## Step 5: Verify

Immediately after execution completes, verify the task against its acceptance criteria:

1. For EACH acceptance criterion:
   - Read the relevant code that was just written.
   - Run tests if applicable.
   - Produce a **pass/fail** verdict with evidence (file:line references).

2. Present the verification report:

```
Verification: Task #<id> — <title>
────────────────────────────────────
[PASS] <criterion 1>
      → src/SomeFile.cs:42
[PASS] <criterion 2>
      → src/SomeFile.cs:58, tests/SomeTest.cs:23
[FAIL] <criterion 3>
      → No test found for this scenario
────────────────────────────────────
Result: X/Y criteria passed
```

3. If **ALL pass**: update task status to `done`.
4. If **any FAIL**:
   - Update task status to `needs_rework`.
   - List specific failures.
   - Ask the user: fix now, update the spec, or skip and move on?
   - If "fix now": attempt the fix, re-run verification for failed criteria only.

**Verification rules:**
- Verification is mechanical, not creative. Check criteria, produce evidence, pass/fail.
- Always provide file:line evidence for each verdict.
- **Always run the build** as part of verification. A task that doesn't build is not done — period.
- **Always run relevant tests** as part of verification. If tests were written for this task, run them. If existing tests cover the changed code, run those too.
- Build and test results are MANDATORY evidence in the verification report, not optional.
- If a criterion is ambiguous and cannot be mechanically verified, flag it as `[WARN]`.

---

## Step 5b: Commit (optional)

This step runs ONLY when ALL of the following are true:
- `$ARGUMENTS` contains `--commit`
- Verification passed (all criteria PASS, task status set to `done`)

If those conditions are met:

1. Stage all files changed during this task (new files and modified files). Do NOT use `git add -A` or `git add .` — stage specific files only.
2. Create a commit with a message in this format:
   ```
   feat(<feature-slug>): Task #<id> — <task title>

   Acceptance criteria met:
   - <criterion 1>
   - <criterion 2>
   ```
3. Print the commit hash and summary.

**Commit rules:**
- **NEVER push.** Commit locally only. No `git push` under any circumstance.
- If verification failed or the task status is `needs_rework`, skip this step entirely — do not commit broken work.
- Do not amend existing commits. Always create a new commit.
- Do not commit files that look like secrets (`.env`, credentials, keys).

---

## Step 6: Show the dashboard

**Regardless of the outcome above**, always finish by printing the full status dashboard:

```
SDD Status: <feature-slug>
═══════════════════════════════════════════════════════
 #  Task                              Cx  Ready  Status
 1  <task title>                       2  yes    done
 2  <task title>                       3  yes    done
 3  <task title>                       5  yes    done  <-- just completed
 4  <task title>                       4  no     pending (blocked: #3)
═══════════════════════════════════════════════════════
Progress: X/N done | Next: <appropriate suggestion>
```

Rules for the dashboard:
- Order tasks by ID.
- For `pending` tasks where `ready` is false, append `(blocked: #<dep_ids>)`.
- Always include a "Next action" line:
  - More ready tasks → "Run `/sdd-next` to continue"
  - Blocked tasks → "Run `/sdd-5-refine` to unblock"
  - All done → "Run `/sdd-review` for final review"

---

## Reminders

- **Never auto-execute.** Always ask for confirmation before starting implementation.
- **Full cycle:** This command does pick → execute → verify in one flow.
- Use `/sdd-execute <id>` and `/sdd-verify <id>` separately only when you need manual control over individual steps.
- Always show the full dashboard at the end.
- Update the tasks JSON file to reflect all status changes.
