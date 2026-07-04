---
name: help
description: Display the SDD skill reference and workflow guide
---

Display the Spec-Driven Development (SDD) skill reference and suggested workflow. Do NOT run any tools or modify any files. Simply print the following guide exactly as written:

---

## SDD Skills — Spec-Driven Development

Move thinking to the front. Make execution mechanical.

### Suggested Workflow

```
  /sdd-init .................. One-time setup: create .specs/ and AGENTS.md
        |
        v
  /sdd-1-negotiate ........... Agent interviews you to extract requirements
        |
        v
  /sdd-2-specify ............. Generate a PRD from the interview
        |
        v
  /sdd-3-decompose ........... Break the PRD into 3-10 tasks
        |
        v
  /sdd-4-research ............ Score each task's complexity (1-10)
        |
        v
  /sdd-5-refine .............. Check readiness + auto-decompose complex tasks
        |
        v
  +--------------------------------------+
  |  Developer Loop                      |
  |                                      |
  |  /sdd-next ....................... Pick → Execute → Verify (full cycle)
  |        |                             |
  |        +-------> next task ----------+
  |                                      |
  +--------------------------------------+
        |
        v  (all tasks done)
  /sdd-status ................ Confirm every task is done; re-check the PRD by hand
```

### All Commands

**Spec Pipeline (numbered — run once, in order)**

| # | Command | What it does |
|---|---------|-------------|
| 1 | `/sdd-1-negotiate` | Structured interview — agent asks you questions one at a time |
| 2 | `/sdd-2-specify` | Write the PRD from your answers → `.specs/<slug>/prd-<slug>.md` |
| 3 | `/sdd-3-decompose` | Break PRD into tasks → `.specs/<slug>/tasks-<slug>.json` |
| 4 | `/sdd-4-research` | Analyze each task for complexity, risks, and unknowns |
| 5 | `/sdd-5-refine` | Check 6-point readiness checklist, mark tasks as ready. Auto-decomposes tasks with complexity 7+ into smaller subtasks. |

**Developer Loop (unnumbered — use repeatedly)**

| Command | What it does |
|---------|-------------|
| `/sdd-next [--commit]` | **Preferred.** Pick next ready task → execute → verify. Add `--commit` to auto-commit on success (never pushes). |
| `/sdd-execute <id>` | Manual: implement a specific task only (no verify) |
| `/sdd-verify <id>` | Manual: verify a specific task only (no execute) |

**Utilities (unnumbered — use anytime)**

| Command | What it does |
|---------|-------------|
| `/sdd-init` | Create `.specs/` directory, add to `.gitignore`, scaffold `AGENTS.md` |
| `/sdd-status` | Dashboard: see all tasks, progress, and what to do next |
| `/sdd-help` | Show this guide |

### Quick Tips

- **Already have a PRD?** Skip to `/sdd-3-decompose`.
- **Just checking in?** Run `/sdd-status` anytime.
- **Just keep going?** `/sdd-next` picks, executes, and verifies in one shot.
- **All tasks done?** Run `/sdd-status` to confirm, then re-read the PRD's acceptance criteria by hand — there's no dedicated whole-feature review command yet.
- **Multiple features?** Each gets its own folder under `.specs/`. Skills auto-detect or ask you to pick.
- **Progress tracking:** `/sdd-execute`, `/sdd-verify`, and `/sdd-next` automatically append entries to `.specs/<slug>/progress-<slug>.md` so you always have a human-readable history of what was done, when, and by whom.

---
