---
name: status
description: Show the SDD status dashboard (read-only)
---

# SDD Status Dashboard

You are executing the `/sdd-status` command. This is a **read-only** command. You MUST NOT modify any files.

**Arguments received:** $ARGUMENTS

---

## Step 1: Scan `.specs/`

Scan the `.specs/` directory to discover all features.

**How to scan:** Use the **Read tool** on the `.specs/` directory path — this is the primary method because it works on all platforms (macOS, Linux, Windows) without depending on any shell command. Do NOT rely on `fd`, `find`, `ls`, or other CLI tools that may not exist on all platforms. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

**Verify existence:** Before concluding `.specs/` doesn't exist, try BOTH the Read tool AND a Bash command. A single failed attempt is NOT proof the directory is missing.

For each **subdirectory** found, check for:
- `prd-<slug>.md` — the PRD file
- `tasks-<slug>.json` — the tasks file

Also check for **loose PRD files** directly in `.specs/` root (files matching `*prd*.md` that are not inside a feature folder). These represent features that were created outside the standard workflow.

Build a feature inventory with these fields per feature:
- **slug**: the folder name (or derived from the loose PRD filename)
- **phase**: determined by what files exist (see phase detection below)
- **progress**: task counts if tasks exist
- **location**: `folder` or `loose` (for PRDs not in a subfolder)

### Phase detection

| Files present | Phase |
|---------------|-------|
| Only `prd-<slug>.md` (no tasks file) | `prd` |
| `tasks-<slug>.json` exists | Parse task statuses (see below) |
| Loose PRD in `.specs/` root | `prd (orphaned)` |

When tasks exist, determine execution phase from statuses:
- All tasks `pending` or `decomposed` → `decomposed`
- Any task `in_progress` → `in_progress`
- Any task `awaiting_verification` and none `in_progress` → `verifying`
- All tasks `done` → `complete`
- Mix of `done` and `pending`/`in_progress` → `in_progress`

If no `.specs/` directory or no features exist (confirmed by at least two methods), tell the user no features exist yet and suggest running `/sdd-2-specify`.

---

## Step 2: Determine display mode

Parse `$ARGUMENTS`:

- **No arguments** → go to **Step 3** (global overview).
- **Non-numeric string** (a slug) → go to **Step 4** (feature dashboard). If the slug also contains a number, treat the number as a task ID and go to **Step 5** (single-task detail).
- **Number only** → If exactly one feature exists, auto-select it and go to **Step 5** (single-task detail). If multiple features exist, show the global overview with a note: "Multiple features found. Use `/sdd-status <slug> <task-id>` to view a specific task."

---

## Step 3: Global overview

Display a summary table of ALL discovered features:

```
SDD Overview
═══════════════════════════════════════════════════════════════════
 Feature                                Phase          Progress
 server-test-coverage-50                in_progress    0/18 done, 1 in progress
 album-rollover-cleaning-fallback       prd            not decomposed
═══════════════════════════════════════════════════════════════════
```

Rules:
- Order features alphabetically by slug.
- For features with tasks, show a compact progress summary: `X/N done[, Y in progress][, Z awaiting verification]`. Only mention statuses with count > 0.
- For features without tasks (phase `prd`), show `not decomposed`.
- For loose PRDs (phase `prd (orphaned)`), append `(file not in folder — run /sdd-2-specify to fix)`.
- After the table, show: `Use /sdd-status <slug> for details on a specific feature.`

Then go to **Step 6** (suggest next action).

---

## Step 4: Feature dashboard

Read the tasks file at `.specs/<slug>/tasks-<slug>.json`. If the feature has no tasks file (PRD-only), display:

```
Feature: <slug>
Phase: PRD written — not yet decomposed.
PRD: .specs/<slug>/prd-<slug>.md

Next action: Run `/sdd-3-decompose <slug>` to break this PRD into tasks.
```

Then stop (no need for Step 6).

If the tasks file exists, print the full task table:

```
SDD Status: <feature-slug>
═══════════════════════════════════════════════════════
 #  Task                              Cx  Ready  Status
 1  <task title>                       2  yes    done
 2  <task title>                       3  yes    awaiting_verification
 3  <task title>                       5  yes    in_progress
 4  <task title>                       4  no     pending (blocked: #3)
═══════════════════════════════════════════════════════
Progress: X/N done | Y in progress | Z awaiting verification
```

Rules for the table:
- Order tasks by ID.
- For `pending` tasks where `ready` is false, append `(blocked: #<dep_ids>)` listing the IDs of dependencies that are not yet `done`.
- Show the Ready column as `yes` or `no`.
- The Progress line counts tasks by status. Only mention statuses that have at least one task.

Also check for `.specs/<slug>/progress-<slug>.md`. If it exists, you may reference it for historical context when showing task details.

Then go to **Step 6** (suggest next action).

---

## Step 5: Single-task detail view

Find the task matching the given numeric ID within the resolved feature. If not found, say so and show the feature dashboard (Step 4) instead.

If found, display a detailed view with ALL of the following fields:

```
Task #<id>: <title>
Status: <status>
Complexity: <complexity> — <complexity_rationale>
Ready: <yes/no>

Description:
  <description>

Acceptance Criteria:
  - [ ] <criterion 1>
  - [ ] <criterion 2>
  ...

Dependencies:
  - #<dep_id> <dep_title> (<dep_status>)
  ...

Risks:
  - <risk>
  ...

Unknowns:
  - <unknown>
  ...

Non-Goals:
  - <non_goal>
  ...
```

For dependencies, look up each dependency ID in the tasks list and show its current title and status. If a dependency is not `done`, flag it clearly (e.g., "BLOCKING").

Then go to **Step 6** (suggest next action).

---

## Step 6: Suggest next action

After every output (whether overview, feature dashboard, or single-task), you MUST suggest the most logical next action. Evaluate in this priority order:

### For global overview:
1. Any feature has `prd (orphaned)` → "Orphaned PRD found. Run `/sdd-2-specify` to create it properly in a feature folder."
2. Any feature in `prd` phase → "Feature `<slug>` has a PRD but no tasks. Run `/sdd-3-decompose <slug>`."
3. Any feature in `in_progress` or `verifying` → "Feature `<slug>` has active work. Run `/sdd-status <slug>` for details."
4. All features complete → "All features complete! Run `/sdd-review <slug>` for final review."

### For feature dashboard or single-task detail:
1. **Tasks with `status: needs_rework`** exist → "Next action: Re-execute reworked tasks. Run `/sdd-execute <slug> <id>` for: #X, #Y"
2. **Tasks with `status: awaiting_verification`** exist → "Next action: Verify completed work. Run `/sdd-verify <slug> <id>` (suggest the lowest ID)"
3. **Tasks with `status: pending` and `ready: true`** exist → "Next action: Execute the next ready task. Run `/sdd-next <slug>` or `/sdd-execute <slug> <id>`"
4. **Tasks with `status: pending` and `ready: false`** exist (but none are ready) → "Next action: Refine blocked tasks. Run `/sdd-5-refine <slug>`"
5. **All tasks are `done`** → "All tasks complete! Run `/sdd-review <slug>` for a final review."
6. **No tasks exist** → "No tasks found. Run `/sdd-3-decompose <slug>` to break down the PRD."

---

## Reminders

- This command is **strictly read-only**. Do NOT create, modify, or delete any files.
- Always show the "Next action" line. The dashboard must be actionable.
- Keep output clean and scannable. Use monospace formatting for the table.
- When suggesting commands for a specific feature, ALWAYS include the `<slug>` in the command to avoid ambiguity when multiple features exist.
