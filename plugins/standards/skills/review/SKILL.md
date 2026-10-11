---
name: review
description: Review the changes since a fixed point (commit, branch, tag, merge-base or a PR) along two axes, Standards (rule ids from the coding standards, the project's rules block, glossary and ADRs) and Spec (the originating item), with extra reviewers for tests, security and performance when the diff touches them. Parallel review agents, severity from the rule tag, a refutation pass on every blocker, findings side by side, optional PR comments. Use when the user wants to review a branch, a PR, work in progress, or asks to review since X.
---

Review the diff between a fixed point and the work under review. Two axes, never merged:

- **Standards**: does the touched code follow the coding standards (by rule id), the project's
  rules block, its `## Glossary` and its ADRs?
- **Spec**: does the code do what the originating item asked, and nothing more?

Reviewers run as parallel agents so their contexts stay clean. This skill pins the inputs,
spawns them, runs the refutation pass and aggregates.

## 1. Pin the fixed point

- **A PR number or URL** → PR mode. `gh pr view <#> --json title,body,baseRefName,headRefName,url`;
  diff with `gh pr diff <#>`. The fixed point is the base branch; the spec comes from
  `Resolves #n` in the body.
- **An explicit ref** (SHA, branch, tag, `HEAD~5`) → use it as given.
- **Nothing given** → on a non-default branch, the merge-base with the default branch; say so. On
  the default branch with no other signal, ask.

Diff command: `git diff <fixed-point>...HEAD` (three dots). Commit list:
`git log <fixed-point>..HEAD --oneline`. Confirm the ref resolves and the diff is not empty before
spawning anything.

## 2. Find the spec

In this order: `Resolves #n` in the PR body; an issue reference in the commits or PR body; a
tracker id the user passed; a flow item under `.flow/items/`; a spec file under `docs/` or
`specs/` matching the branch. GitHub items: `gh issue view <#>` (plus the parent epic's scope and
out-of-scope when there is one). Another tracker: ask the user to paste it. No spec: the Spec
reviewer is skipped and the report says so.

## 3. Find the standards sources

- The installed block in `AGENTS.md` (or `CLAUDE.md`) between the `standards:begin` and
  `standards:end` markers, and the full text in `.standards/rules/`. If neither exists, use the
  plugin's own `rules/` directory and say the project has not run `init`.
- Project rules outside the block, the `## Glossary`, and `docs/adr/`.
- `.standards/config.json` for `hot_paths` and `review.security_paths` /
  `review.performance_paths`.

Skip what tooling enforces (the build, the formatter, the hooks). The reviewers get this list and
the rule index; they do not search for it.

## 4. Spawn the reviewers in parallel

Always: the `standards-reviewer` and, when a spec exists, the `spec-reviewer`.
When the diff touches them: `test-reviewer` for test files, `security-reviewer` for files under
`review.security_paths` or any file handling input, auth, storage or network, and
`performance-reviewer` for files under `hot_paths` or `review.performance_paths`.

**Project reviewers.** When `.standards/config.json` names `project.roster`, read that roster:
every agent with `"step": "review"` and a `paths` list is spawned too when any file in the diff
matches one of its globs (`**` spans directories), by its name (`init` renders it for both
hosts). It gets the same prompt and scale and reports under its own heading (`## <name>`),
never merged into the two axes.

Each prompt carries: the diff command and commit list, the standards sources from step 3 (paths,
not contents), the spec text or path, and the grading scale:

- **P0**: a broken [hard] rule, a glossary term misused, an ADR contradicted, a required
  behaviour missing or wrong, scope creep into a stated non-goal. Blocks.
- **P1**: a crossed [signal] with no explanation in the commit or PR, a partial requirement, a
  smell from the baseline in the standards-reviewer brief. Blocks until explained.
- **P2**: a [judgement] disagreement or a nit. A comment.

Every finding: grade, rule id (or spec line), file and line, what is wrong, the fix. Touched
code only. Under 400 words per reviewer.

## 5. Refute the blockers

For each P0 and P1, spawn one more `standards-reviewer` (or `spec-reviewer` for spec findings)
with a refutation brief: "Here is a finding. Try to knock it down: is the rule misread, is the
code outside the touched scope, is the breach declared in the commit or PR body, is it enforced
by tooling already?" A finding survives only if the refuter cannot. Drop the ones that fall and
say how many fell.

## 6. Aggregate

Present `## Standards` and `## Spec` (and `## Tests`, `## Security`, `## Performance` and one
heading per project reviewer when they ran), each with its surviving findings and a verdict from its worst finding: **FAIL** (any P0),
**PASS WITH NOTES** (P1 or P2 only), **PASS** (clean). Never rerank across axes. End with one
line per axis: verdict, count, worst finding.

## 7. Post (PR mode, on request)

Confirm before posting. One `gh pr comment <#> --body "..."` per finding:
`**[P0] Standards** — path:line — what is wrong — rule id or spec line — the fix`.
Then one closing comment with the verdict per axis.

## Why two axes

Code can follow every rule and do the wrong thing, or do the right thing and break the rules.
Reporting them apart stops one from hiding the other.
