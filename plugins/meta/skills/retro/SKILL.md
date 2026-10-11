---
name: retro
description: Retrospective that turns lessons into routed, concrete changes to the standards, the skills, the hooks and the project docs. Reads the flow's lessons log and the session, proposes each change with its durable home, and applies the approved ones, as a PR to the marketplace when a rule or skill changes.
disable-model-invocation: true
---

# Retro

Output: routed, concrete improvements, never a reflection essay. Every finding names a durable
home and a specific change. Three routed improvements beat a page of observations; an honest
"nothing worth changing" is a valid retro.

## 1. Collect

- **The lessons log** `.flow/lessons.jsonl` in the project (one JSON line per escalation and per
  review blocker, with `kind`, `item`, `step`, `rule`, `text`). Read the lines since the last
  retro (the last line of `.flow/retros.log`, written in step 4; all lines on the first run).
- **The session** (manual form): the goal, what changed, which skills and agents ran.
- **The lenses**: repetitive work; bottlenecks (prompts, denied tools, slow loops, round-trips
  for ambiguity); corrections the owner made; what worked and should be the default; wrong
  turns and their cause; rediscovered facts; decisions worth pinning; calibration (over-asking,
  over-verifying, over-explaining); a mistake a machine could have caught; information the
  agent could not reach; expensive tool calls; standing instructions that changed nothing.

Cluster the lessons: the same rule id or the same step failing twice is a theme; a theme is a
finding, a single unflagged instance is not.

## 2. Route each finding

| finding | durable home | via |
|---|---|---|
| a rule agents keep breaking, or a missing rule | `docs/coding-standards.md` in the marketplace (the owner approves; W-06) and the plugin that enforces it | PR to the marketplace |
| a mechanical breach (a pattern, a banned API, a file location) | a hook or a lint check in `standards`, or the project's CI | PR to the marketplace, or Edit in the project |
| a step agent that misreads its job | that agent's brief in `roster/briefs/` | PR to the marketplace |
| a skill that misfires or has a fuzzy trigger | that skill's description or body | PR to the marketplace |
| a repeatable procedure with no skill | a new skill | `write-a-skill` |
| a project fact, constraint or glossary term | the project's `AGENTS.md`, glossary or `docs/adr/` | Edit in the project |
| a decision not to re-litigate | an ADR | Edit in the project |
| a gate the owner answers the same way every time | the profile or `.flow/config.yaml` (feel-test paths, gates) | PR to the marketplace, or Edit |
| information the agent could not reach | a teed log, a read-only token, a script | Edit in the project |
| a standing instruction that changed nothing | delete it | Edit |

Standards belong to the reviewer, not the implementer: a new coding rule goes to the standards
file and the review engine, never to the always-loaded project rules. A mechanical breach gets a
machine check before a written rule.

## 3. Report

Findings grouped by home, highest leverage first, each as **what happened → the change → where
it lands**, with the lesson lines that support it. Then ask which to apply.

## 4. Apply

- Marketplace changes: in the marketplace repo (the owner names its path; `/work/brain` here),
  on a branch `retro/<date>`, the edits, `tools/generate.sh`, `tools/test.sh`, then a PR
  (`gh pr create`) titled `retro: <summary>` with the findings as the body. Only the owner
  merges; a standards change changes the enforcing plugin in the same PR (W-06).
- Project changes: the edits in the project, uncommitted, listed in the report.
- Append one line to `.flow/retros.log`: `<time>\t<lessons read so far>\t<findings>\t<applied>`,
  where the second column is the total number of `lessons.jsonl` lines read to date (the
  scheduled job subtracts it from the line count to find the new lessons).

## Unattended

When the prompt says unattended (the weekly `flow` job runs this skill under `claude -p` or
`codex exec`), nobody answers. Skip the question in step 3. Apply every marketplace finding
as the PR in step 4; the owner reviews it there. Do not edit the project: write the project
findings, with the exact edits proposed, to `.flow/reports/retro-<date>.md` together with the
report, and append the `retros.log` line. "Nothing worth changing" writes the report and the
log line and opens no PR.

## Never

- Never manufacture a finding to look thorough. Never legislate a one-off. Never reopen a
  pinned decision. Never merge the marketplace PR yourself.
