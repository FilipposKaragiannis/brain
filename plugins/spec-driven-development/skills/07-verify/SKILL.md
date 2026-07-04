---
name: 07-verify
description: Verify a completed task against its acceptance criteria
---

You are executing Phase 7 of SDD: Task Verification. Your job is to mechanically verify a completed task against its acceptance criteria. You do NOT fix issues — you report them with evidence and let the user decide.

## Input

Arguments: `$ARGUMENTS`

Parse the arguments to extract:
- **Task ID** (required): a numeric value identifying the task to verify.
- **Feature slug** (optional): a non-numeric word identifying the feature.

If no task ID is found, stop immediately and print:
```
Usage: /sdd-verify <task-id> [feature-slug]
Example: /sdd-verify 3
Example: /sdd-verify 3 autoconfig-cleanup
```

## Step 1: Resolve the Feature

**To scan `.specs/`**, use the **Read tool** on the `.specs/` directory — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`) to list directories. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

Apply feature resolution in this order:
1. If `$ARGUMENTS` contains a non-numeric word, treat it as the feature slug.
2. If only one folder exists under `.specs/` (check via Read tool), auto-select that feature.
3. If multiple folders exist under `.specs/`, list them all and ask the user to specify which one.

Once resolved, the feature files are:
- Tasks file: `.specs/<slug>/tasks-<slug>.json`
- PRD file: `.specs/<slug>/prd-<slug>.md`

Read the tasks file. Its structure is `{ "feature": "<slug>", "prd": "prd-<slug>.md", "tasks": [...] }`.

## Step 2: Locate the Task and Validate Status

Find the task with the matching ID in the tasks array.

If the task is not found, print an error listing all available task IDs and their titles.

Check the task's `status` field:
- `awaiting_verification` or `needs_rework`: proceed with verification.
- `done`: warn that this task is already verified, ask if the user wants to re-verify.
- `pending` or `in_progress`: warn that this task has not been completed yet. Print: "This task is still `<status>`. Run `/sdd-execute <task-id>` to implement it first." Ask the user if they want to proceed anyway.

## Step 3: Read Acceptance Criteria

Extract the `acceptance_criteria` array from the task object. Each criterion is a string describing a specific, verifiable condition.

If the task has no acceptance criteria, flag this as an error — every task should have criteria.

## Step 4: Verify Each Criterion

For EACH acceptance criterion, perform a mechanical check:

1. **Understand what the criterion requires.** Parse it into a concrete, checkable condition.
2. **Search the codebase for evidence.** Read relevant source files, test files, and configuration files. Use the available search and Read tools to find implementations.
3. **Run tests if applicable.** If the criterion involves tests and you can identify the test command (look for package.json scripts, Makefiles, .csproj test projects, etc.), run them.
4. **Produce a verdict:**
   - **PASS**: The criterion is fully met. Cite the specific file(s) and line number(s) as evidence.
   - **FAIL**: The criterion is not met. Explain what is missing or wrong, referencing what you expected to find and where you looked.
   - **WARN**: The criterion is ambiguous and cannot be mechanically verified, OR is partially met with a minor deviation. Explain why you cannot make a definitive pass/fail judgment.

Rules for verification:
- Be thorough. Read actual code, do not guess.
- Always provide `file:line` references for PASS verdicts.
- For FAIL verdicts, explain where you looked and what was missing.
- **Always run the build** as part of verification. A task that doesn't compile is not verified — period. Build failure is an automatic FAIL for all criteria.
- **Always run relevant tests** as part of verification. If tests were written for this task, run them. If existing tests cover the changed code, run those too. Test results are mandatory evidence.
- Build and test results MUST appear in the verification report. Do not skip them or mark them as WARN.
- Do NOT attempt to fix anything. Your role is auditor, not implementer.
- If a criterion references a specific pattern, class, method, or behavior, search for it explicitly.

## Step 5: Present the Verification Report

Format the report exactly like this:

```
Task <ID>: <Task Title>
────────────────────────────────────
[PASS] <Criterion text>
       → <file>:<line> (brief explanation)

[FAIL] <Criterion text>
       → <explanation of what's missing or wrong>

[WARN] <Criterion text>
       → <explanation of ambiguity or partial compliance>
────────────────────────────────────
Result: X/Y criteria passed | Z warnings | W failures
```

## Step 6: Update Task Status

After presenting the report:

- **All criteria PASS (warnings are acceptable):** Update the task's `status` to `"done"` in the tasks JSON file. Print a confirmation.
- **Any criteria FAIL:** Update the task's `status` to `"needs_rework"` in the tasks JSON file. Then:
  1. List the specific failures clearly.
  2. Ask the user how they want to proceed:
     - **Fix now**: suggest running `/sdd-execute <task-id>` again to address the failures.
     - **Update spec**: the criterion may be wrong or outdated — offer to adjust it.
     - **Skip**: mark as done anyway (user accepts the deviation).

When updating the tasks file, read it, modify only the target task's status field, and write it back preserving all other data.

## Step 6b: Update the progress log

Append a verification entry to `.specs/<slug>/progress-<slug>.md`. Create the file if it does not exist. Use this format:

```markdown
## Verification: Task #<id>: <title>
- **Result:** <PASSED — marked done | FAILED — marked needs_rework>
- **Date:** <current date YYYY-MM-DD>
- **Criteria:** <X/Y passed, Z failed>
- **Failures:** <list failed criteria, or "none">
```

Never overwrite existing entries — always append.

## Step 7: Print Status Dashboard

After the status update, print a compact dashboard of ALL tasks in the feature:

```
Status Dashboard: <feature-slug>
──────────────────────────────────
  #  Status                Title
  1  done                  Task one title
  2  done                  Task two title
  3  needs_rework          Task three title   ← current
  4  pending               Task four title
──────────────────────────────────
Progress: X/Y tasks done
```

Mark the current task with an arrow indicator.

## Critical Rules

1. **Verification is MECHANICAL.** You are an auditor. Check criteria, produce evidence, pass or fail. No creativity.
2. **Do NOT fix failures.** Report them. Let the user decide the next action.
3. **Always provide file:line evidence.** Every PASS needs a source reference. Every FAIL needs an explanation of where you looked.
4. **Read actual code.** Do not rely on task status or descriptions. Open files and verify.
5. **One task at a time.** This command verifies a single task. There's no dedicated whole-feature review command yet — once every task is `done`, re-check the implementation against the PRD's acceptance criteria by hand.
