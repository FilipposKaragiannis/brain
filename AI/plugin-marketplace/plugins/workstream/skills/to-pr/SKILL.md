---
description: Take completed, verified work to a pull request — run the test suite green, show a concise diff summary and pause for the user's manual feel-test and approval, then commit on the working branch, push, and open a PR via gh (following the repo's conventions) that tags @codex and @claude for review. Use after ship.
---

# workstream: to-pr

Take the work `ship` just completed from "done in the working tree" to "open PR." Three hard gates, in order: **tests green → user feel-test + approval → commit/push/PR.** Never skip or reorder a gate.

## 1. Run the test suite — must be green

Find the test command in priority order: `CLAUDE.md` / `AGENTS.md` conventions first, then the project's build files (`package.json` scripts, `Makefile`, `*.csproj` / `dotnet test`, `pytest`, `cargo test`, `go test`, the Unity Test Runner, etc.). Run the relevant suite.

- If anything fails, **STOP** and report — never open a PR on red tests.
- If there is genuinely no test suite, say so and ask the user whether to continue anyway.

## 2. Diff summary + feel-test gate

Show a CONCISE summary — not the full diff:

```
git status --short
git diff --stat
```

Add 2-4 plain-English bullets on what changed and why. Then ask the user to **manually feel-test** the change — run it the way the app actually runs (e.g. play the scene in the Unity editor / launch the app) — and explicitly approve.

**Wait for approval. Commit nothing until the user approves.** If they report problems, stop and hand back (usually re-run `ship`).

## 3. On approval: commit, push, open the PR

### Branch
Check the current branch (`git branch --show-current`). If it's the default branch (`main` / `master`), create a working branch first: `ws/<issue#>-<short-slug>`. Otherwise commit on the current working branch.

### Commit
Stage the work explicitly (never commit `.env`, keys, or other secrets). Write a commit message following the repo's conventions (check `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md`), and end it with the Claude Code `Co-Authored-By` trailer for the active model.

### Push
`git push -u origin <branch>`.

### Open the PR
Follow the repo's PR guidelines — read `.github/PULL_REQUEST_TEMPLATE.md` and `CONTRIBUTING.md` if present and fill the template. Create it with `gh pr create --title "<title>" --body "<body>"`.

The PR body MUST:

- Summarize the change and link the shipped slice: `Resolves #<issue#>`.
- Include a **Reviews** section tagging the bots:

  ```
  ## Reviews
  @codex — requesting review.
  @claude — requesting individual (line-by-line) review.
  ```

- End with the Claude Code footer: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

### Mark the slice in review

After the PR is open, move the slice to the **in review** state — do NOT close it:

```
gh issue edit <issue#> --add-label "status:in-review"
```

Because the PR body carries `Resolves #<issue#>`, GitHub auto-closes the issue when the PR merges to the default branch — that is when its parent epic's progress bar advances (if the issue has one). There is no manual close on this path.

Print the PR URL when done; if the issue has a parent epic, suggest `board <epic#>`.

## Rules

- Three gates in order: green tests → explicit user approval → PR. Never skip one.
- Push and open the PR only after the user approves in step 2.
- Never commit straight to the default branch — always a working branch.
- Never close the issue — mark it `status:in-review`; the merge closes it (via `Resolves #<issue#>`).
