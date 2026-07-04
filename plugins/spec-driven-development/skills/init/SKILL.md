---
name: init
description: Initialize the .specs/ directory for Spec-Driven Development
---

You are bootstrapping the `.specs/` directory for the Spec-Driven Development (SDD) workflow. SDD is a methodology where each feature begins as a PRD (Product Requirements Document) that gets decomposed into a task list. Both artifacts live inside `.specs/<feature-slug>/` as `prd-<slug>.md` and `tasks-<slug>.json`.

Follow these steps in order. Be idempotent: never delete or overwrite existing files.

## Step 1 — Ensure `.specs/` exists

Check whether a `.specs/` directory exists at the project root. **Use the Read tool** to check — this works on all platforms (macOS, Linux, Windows). Do NOT use shell commands (`ls`, `find`, `fd`, `dir`, `test -d`) to check directory existence. If the Read tool fails, fall back to Bash. If Bash is unavailable (e.g., Windows without WSL), use PowerShell (`Get-ChildItem`) or cmd (`dir`).

- If it does NOT exist, create it using the Write tool (write any file inside it, e.g., a `.gitkeep`), or use Bash as a fallback.
- If it already exists, note that and continue.

## Step 2 — Ensure `.specs/` is gitignored

Read `.gitignore` at the project root (create the file if it does not exist).

- If `.specs/` (or `.specs`) is NOT already listed as an ignored pattern, append a blank line and the following block to the end of the file:

```
# SDD working specs (personal artifacts, share manually)
.specs/
```

- If it is already ignored, do nothing.

## Step 3 — Inventory existing features

Scan `.specs/` using the **Read tool** to list its contents. Each subdirectory represents a feature. For each one, check for the presence of `prd-<slug>.md` and `tasks-<slug>.json` (using the Read tool) and note their status (present / missing). Also check for loose PRD files (files matching `*prd*.md` directly in `.specs/` root, not inside a feature folder).

## Step 4 — Optionally scaffold `AGENTS.md`

Check whether `AGENTS.md` exists at the project root.

- If it already exists, skip this step entirely.
- If it does NOT exist, ask the user:

> "No AGENTS.md found. Would you like me to create a starter one? I'll ask a few quick questions about your project conventions."

If the user declines, skip to Step 5.

If the user agrees, conduct a brief interview by asking these questions one at a time (wait for each answer before asking the next):

1. **Tech stack**: "What languages, frameworks, and key libraries does this project use?"
2. **Code style**: "Any naming conventions, formatting rules, or style guides I should know about? (e.g., camelCase, Prettier, ESLint config)"
3. **Project boundaries**: "Are there areas of the codebase I should never modify, or files that are auto-generated?"
4. **Testing**: "How are tests organized and run? Any conventions for test naming or placement?"
5. **Other conventions**: "Anything else an AI agent should know before working in this repo?"

After collecting answers, generate `AGENTS.md` at the project root with the following structure:

```markdown
# AGENTS.md

> Project conventions and guardrails for AI coding agents.

## Tech Stack
<filled from answer 1>

## Code Style
<filled from answer 2>

## Boundaries
<filled from answer 3>

## Testing
<filled from answer 4>

## Additional Conventions
<filled from answer 5>
```

Fill each section with the user's answers. If the user skipped or gave an empty answer for a section, include the heading with a placeholder: `_No conventions specified yet._`

## Step 5 — Print summary

Print a clear summary of everything that happened. Use this format:

```
SDD Init Summary
================
.specs/ directory  : <created | already existed>
.gitignore updated : <yes | already had .specs/ ignored>
Existing features  : <list feature slugs, or "none">
AGENTS.md          : <created | already existed | skipped>
```

If the project was already fully initialized (nothing needed to be created or changed), print:

```
SDD is already initialized in this project. Nothing to do.
```

$ARGUMENTS
