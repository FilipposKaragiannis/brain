---
name: to-pr
description: Take completed, verified work to a pull request — green tests, a feel-test approval gate, then commit/push/PR with bot review requests. Use after ship.
disable-model-invocation: true
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
Stage the work explicitly (never commit `.env`, keys, or other secrets). Write a commit message following the repo's conventions (check `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md`).

### Push
`git push -u origin <branch>`.

### Open the PR
Follow the repo's PR guidelines — read `.github/PULL_REQUEST_TEMPLATE.md` and `CONTRIBUTING.md` if present and fill the template.

**Pick the base branch first.** The PR base is the branch the working branch was forked from (usually the corresponding `epic/*`), **never `main` by default**. If you're unsure of the fork-parent, **ask before opening** — don't guess. Pass it explicitly with `--base <fork-parent>`.

Create it with `gh pr create --base <fork-parent> --title "<title>" --body "<body>"`.

The PR body MUST summarize the change and link the shipped slice: `Resolves #<issue#>`.

Do NOT tag the bots in the PR body — tagging there does not reliably trigger a review. Request reviews via individual comments in the next step instead.

### Request reviews — one comment per bot

Tag each bot in its **own** PR comment (never both in one comment, never in the body). Each comment must ask the bot to do two things: (1) review the code line-by-line for correctness, and (2) check the implementation against the linked issue's description / acceptance criteria.

First, if the slice resolves an issue, pull its description so you can point the bots at the actual criteria:

```
gh issue view <issue#> --json title,body
```

Then post two separate comments:

```
gh pr comment <pr-url-or-#> --body "@codex — please review this PR. Go through the diff line-by-line for correctness, then verify the implementation satisfies the description and acceptance criteria of #<issue#>."

gh pr comment <pr-url-or-#> --body "@claude — please do an individual, line-by-line review of this PR for correctness, and verify the implementation meets the description and acceptance criteria of #<issue#>."
```

If there is no linked issue (or it has no acceptance criteria), drop the acceptance-criteria clause and just request the line-by-line code review.

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
- PR base = the branch the working branch was forked from (usually the corresponding `epic/*`), never `main` by default. If unsure of the fork-parent, ask before opening.
- Tag the bots in individual PR comments (one bot per comment), never in the PR body — each comment requests a line-by-line review AND a check against the issue's acceptance criteria.
- Never close the issue — mark it `status:in-review`; the merge closes it (via `Resolves #<issue#>`).
