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
  review blocker, with `kind`, `item`, `step`, `rule`, `text`). It stays on this machine under
  `.flow/`, which is excluded from git: never commit it or `retros.log`. Read the lines whose `time` is
  after the last retro's time (the first column of the last `.flow/retros.log` line, written in
  step 4; all lines on the first run). Trust the times, not a line count: the log can be rewritten.
- **The graph report**, when the retro job names one (`.flow/reports/graph-<date>.md`; by hand,
  the flow plugin's `scripts/graph-report.sh`): per step the runs, the median time, the failed
  runs, the cost and the runs per item, and the steps that got slower since the period before.
  A step that got slower, fails often or runs more than twice per item is a finding: name the
  brief, skill, hook or config that makes it so.
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

The report has three parts. The findings, grouped by home, highest leverage first, each under
the labels **What happened** (with the lesson lines that support it), **The change** (one change,
not a menu of options) and **Where it lands**. The lessons set aside, each with why (a one-off, a
pinned decision). Then the question which findings to apply. Nothing else goes in: a check that
came up clean or a remark on the project is not a finding. Steps 1 to 3 read the project and the
session only: the marketplace checkout is opened in step 4, for the findings the owner approved.

## 4. Apply

- Marketplace changes: in the marketplace checkout (the path the prompt names, else ask the
  owner for it), on a branch `retro/<date>`, the edits, a changelog fragment
  `plugins/<plugin>/changelog.d/retro-<date>.md` for each plugin changed (a `bump:` line, a blank
  line, the bullets; never the version or `CHANGELOG.md`, the release PR folds them),
  `tools/generate.sh`, `tools/test.sh`, then a PR (`gh pr create`) titled `retro: <summary>`
  with the findings as the body. Only the owner merges; a standards change changes the enforcing
  plugin in the same PR (W-06).
- Project changes: the edits in the project, uncommitted, listed in the report.
- Append one line to `.flow/retros.log`: `<time>\t<lessons read so far>\t<findings>\t<applied>`,
  where `<time>` is the UTC time of the run (`date -u +%FT%TZ`; the scheduled job reads the lessons
  after it next time) and the second column is the `lessons.jsonl` line count now.

## Unattended

When the prompt says unattended (the weekly `flow` job runs this skill under `claude -p` or
`codex exec`), nobody answers. Skip the question in step 3. Apply every marketplace finding
as the PR in step 4; the owner reviews it there. With no checkout named, the marketplace findings
go in the report instead. Do not edit the project: write the project findings, with the exact
edits proposed, to `.flow/reports/retro-<date>.md` together with the report, and append the
`retros.log` line. "Nothing worth changing" writes the report and the log line and opens no PR.
The final message names the report and says the project was not edited.

## Never

- Never manufacture a finding to look thorough. Never legislate a one-off. Never reopen a
  pinned decision. Never merge the marketplace PR yourself.
