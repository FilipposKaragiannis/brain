---
name: 02-specify
description: Generate a PRD from interview answers or feature description
---

Generate a PRD (Product Requirements Document) for a feature. This is Phase 2 of the Spec-Driven Development (SDD) workflow.

## Input Resolution

Follow this order to obtain the feature context:

1. If `/sdd-1-negotiate` was run earlier in this session and interview answers are available in the conversation, use those answers as the primary input.
2. Otherwise, if the user provided arguments: $ARGUMENTS -- use that as context. It may be pasted interview answers, a feature description, or a path to existing notes.
3. If neither is available, stop and ask the user to provide context. Offer three options:
   - Paste interview answers or a feature description directly.
   - Point to an existing file with notes (provide a path).
   - Run `/sdd-1-negotiate` first to conduct a structured interview.

Do NOT proceed to PRD generation until you have sufficient context covering: what the feature does, why it exists, who/what uses it, core behaviors, non-goals, and success criteria. If any of these are missing from the input, ask targeted follow-up questions to fill the gaps before generating.

## Feature Slug

Derive a slug from the feature name: lowercase, hyphenated, no special characters. Examples:
- "AutoConfig Cleanup Job" -> `autoconfig-cleanup-job`
- "User Notification Preferences" -> `user-notification-preferences`
- "Fix Auth Token Refresh" -> `fix-auth-token-refresh`

Confirm the slug with the user before writing any files.

## Read Project Conventions

If `AGENTS.md` exists in the project root, read it in full. The PRD you generate MUST respect every convention, pattern, and boundary defined there. Reference specific conventions in the PRD where relevant (e.g., "Per AGENTS.md, all services use constructor injection").

## Scan the Codebase

Before writing the PRD, actively scan the codebase for files relevant to the feature:
- Search for files, classes, functions, and modules related to the feature's domain.
- Look for existing patterns the feature should follow (e.g., how similar features are structured).
- Identify code that will be reused, extended, or integrated with.
- Note any test patterns or test infrastructure that exists.

Collect actual file paths with brief descriptions of their relevance. These go into the "Key Files & References" section. Do NOT leave this section empty or use placeholder paths -- every path must be real and verified.

## Generate the PRD

Write the PRD in markdown with EXACTLY these sections in this order:

### 1. Overview
2-3 sentences summarizing what this feature is and why it matters. A reader should understand the feature's purpose after reading only this section.

### 2. Problem Statement
Explain WHY this feature needs to exist. What pain, gap, or opportunity motivates it? Be specific -- reference real user scenarios or system limitations, not vague statements.

### 3. Solution
High-level approach to solving the problem. Describe the architecture or strategy without getting into implementation details. Mention key design decisions and their rationale.

### 4. Detailed Requirements
Specific behaviors the feature must exhibit, grouped logically under subheadings. Each requirement should be concrete and unambiguous. Use subheadings to organize related requirements (e.g., "### Data Validation", "### Error Handling", "### API Surface").

### 5. Out of Scope
Explicit non-goals. List things this feature will NOT do, especially things a reader might reasonably assume it would do. NEVER skip this section, even if it seems obvious. A missing "Out of Scope" section leads to scope creep during implementation.

### 6. Key Files & References
A list of existing files in the codebase that are relevant to this feature. For each file, include:
- The full relative path from the project root.
- A brief explanation of why it is relevant (e.g., "Pattern to follow for job registration", "Service to extend with new method").

Only include files you have actually verified exist by reading or scanning the codebase. If the codebase has no relevant existing files (e.g., greenfield feature), state that explicitly.

### 7. Acceptance Criteria
A numbered list of criteria that define "done." Every criterion MUST be:
- **Binary**: It either passes or fails. No subjective language ("should be good", "clean code", "performant enough").
- **Testable**: An agent or developer can mechanically verify it by reading code, running a test, or checking output.
- **Specific**: References concrete behaviors, values, files, or states -- not vague goals.

Bad: "The feature works correctly."
Good: "Calling `POST /api/notifications` with a valid payload returns HTTP 201 and persists the notification to the database."

Bad: "Error handling is robust."
Good: "When the external API returns HTTP 503, the service retries up to 3 times with exponential backoff and logs each retry attempt at WARN level."

## Write the PRD

1. Check if the `.specs/` directory exists. If it does not:
   - Create it.
   - Check if `.gitignore` exists. If so, append `.specs/` to it (if not already present). If `.gitignore` does not exist, create it with `.specs/` as the first entry.
2. Create the feature folder `.specs/<slug>/` if it does not exist.
3. Write the PRD to `.specs/<slug>/prd-<slug>.md`.

## Present for Review

After writing the file, display the full PRD content to the user. Then ask:

> "Review the PRD above. You can:
> - **Confirm** it as-is to proceed.
> - **Request changes** -- tell me what to adjust and I will update the PRD.
> - **Iterate** -- ask questions or discuss specific sections before finalizing.
>
> When you are satisfied, run `/sdd-3-decompose` to break this PRD into executable tasks."

If the user requests changes, update the PRD file in place and show the updated version. Repeat until the user confirms.

## Critical Rules

- The PRD must be **self-contained**. A brand-new agent session that reads ONLY this PRD file (and the codebase) must have enough context to understand and implement the feature. Do not rely on conversation history or external documents that are not referenced by path.
- Acceptance criteria are NEVER subjective. Every single criterion must be binary pass/fail. If you catch yourself writing "should be" or "clean" or "appropriate" or "good", rewrite it with a concrete, testable condition.
- NEVER skip the "Out of Scope" section. If the user did not mention non-goals during the interview, infer reasonable ones based on the feature's boundaries and list them. Explicitly excluding things prevents scope creep.
- NEVER fabricate file paths in "Key Files & References." Every path must come from actually scanning the codebase. If a scan turns up nothing relevant, say so.
- If the feature touches areas not covered by the user's input (e.g., error handling, edge cases, permissions), make reasonable decisions and document them in the PRD -- but flag them as assumptions the user should verify.
