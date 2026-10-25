# Filip's brain

Personal plugin marketplace for Claude Code and Codex. One source, two hosts.

## Layout
```
plugins/
  standards/   coding standards as rules, hooks, delivery gate, two-axis review
  flow/        the work flow: adapters (github, local), profiles, next, steward, board, gates
  craft/       codebase-design (with rule ids), improve
  meta/        write-a-skill (scaffolder), retro (lessons log), map (docs/map.html)
shared/        sh/json.sh, copied into each plugin by the generator
roster/        agents.json (every agent, model, effort, tier), briefs/<agent>.md, templates/
tools/         generate.sh, lint.sh, test.sh, eval.sh, cost.sh, host-cleanup.sh, tests/
local/         sync-skills (not shipped)
docs/          coding-standards.md, adr/
```

Each plugin has one hand-written `plugin.source.json`. Everything else under `.claude-plugin/`,
`.codex-plugin/`, `skills/*/agents/openai.yaml`, `agents/` and `codex-agents/` is generated, as
are both marketplace files. See `docs/adr/0001-one-source-two-hosts.md`.

## Work on it
```bash
tools/generate.sh   # render generated files after editing a source, a brief or the roster
tools/lint.sh       # fresh generated files, well-formed skills, roster in step
tools/test.sh       # lint, the suites and `claude plugin validate`; CI runs this
tools/cost.sh       # each plugin's always-on token cost, a warning over budget (needs the claude CLI)
```
`tools/lint.sh` also checks that every hook command names an executable script in its plugin and
that the plugin paths the shipped files name exist; `tools/tests/run.sh` proves it fails on the
broken fixture under `tools/tests/fixtures/`.

## Standards plugin
`standards:init` installs the coding standards in a repo: the rules block in `AGENTS.md`, the
full text and the testing guide under `.standards/`, path-scoped Claude rules, the Codex agents,
the commit hooks and the git hook wiring (the project's own `.githooks/` when it has one, else
`core.hooksPath` at `.standards/hooks/git`), the project's skills and rules links and its rendered
roster (`project` in the config). Hook settings and the project's own gates (`gates`) live in
`.standards/config.json`; CI runs the gates per commit through `plugins/standards/action`. `init` ends
with the gaps (empty commands, guide placeholders) and the `project-advisor` recommends a value for
each from the repository; `init --check` reports gaps until they are filled. Commit message markers:
`[config]` for owner-approved config changes, `[allow-docs]` for doc comments outside public
members, `[why-comment]` for a math or physics `//`. `standards:review` runs the two-axis review.
`init` stamps what it wrote (`.standards/stamp`), refuses to replace a copy edited by hand
(`--force` overrides), and a `SessionStart` hook asks for `init` when the stamp is behind the plugin.
Hook tests: `plugins/standards/hooks/tests/run.sh`. Evals: `tools/eval.sh standards` (costs money, not in CI);
`tools/eval.sh <plugin> --baseline` adds a no-plugin arm to the cases tagged `baseline` (the advisory
skills: `standards:review`, the craft skills) and `--tag negative` runs the should-not-trigger cases.
Each eval run ends with a summary (`tools/lib/eval_summary.py`) that scores the cases over the runs
that did not fail for an infrastructure reason and counts those BLOCKED runs apart.

## Flow plugin
`flow:init` writes `.flow/config.yaml` (adapters, base branch, worktree pool and `pool_max`,
`worktree_copy` and `worktree_setup`, gates, notify), the notify and unattended-run scripts, the
Codex rules and agents, and reports the config gaps. It stamps what it wrote
(`.flow/stamp`), refuses to replace a guarded copy edited by hand, and a `SessionStart` hook asks for
`init` when the stamp is behind the plugin. `flow:next` runs the next
step of an item in a fresh subagent; `advance.sh` applies the step's result file; gates stop
the run and notify. `flow:board` shows the pool, items, gates and overlaps; `flow:steward`
claims and releases pool worktrees and never resets uncommitted work; a claim with no free
worktree grows the pool up to `pool_max` (the entry is appended to the config, the ignored files
copied, the setup commands run). `flow:new` creates an epic, task or bug in the tracker; a child takes its parent's priority and area. Clearing the decomposition gate on a task splits it: step `split`, its worktree back to the pool. `flow:do` takes a plain sentence and routes it to the right skill; `flow:help` is the manual (`help <skill>`, `help lines`, `help gates`); `flow:gate` lists and answers the gates; `auto_gates` in the config lets the flow clear `plan-approval` itself for chosen sizes. `claude --worktree gh-310`
lands in the pool through the project hook `init` prints. The step skills `plan`, `implement`,
`test`, `review`, `verify`, `pr`, `comments` and `explain` run one step on demand with the same
agents and briefs `next` uses; `scripts/verify.sh` is the one verify run, `scripts/comments.sh`
the PR thread plumbing. Unattended: `.flow/run-unattended.sh claude|codex`. Scheduled jobs
(`jobs/`, installed as `.flow/jobs/*.sh`): `comments` every 5 or 10 minutes while PRs are open
(a PR with nothing new costs no model; an open thread awaiting a reply, or a pass the host cut
short, runs again),
`next` at a chosen cadence (`--workers N` runs N items in parallel, capped by the pool;
`notify.idle` says once when nothing is ready), `retro` weekly, `health` every 15 minutes
(`steward.sh health`: clears a dead run, releases an empty claim, resumes cut-off work, syncs clean
task branches, reminds on old gates, says when the pool is full; no model while all is well); each takes the host as its first
argument, locks against overlap and logs to `.flow/log/`. Scheduling is the host's job (Claude
Desktop tasks or launchd); `flow:do` sets one up from "run a repeating unattended flow".
Tests: `plugins/flow/tests/run.sh`. Evals: `tools/eval.sh flow`.

## Craft and meta
`craft:codebase-design` is the design vocabulary with the standards rule ids behind each
principle; `craft:improve` finds deepening candidates and hands the chosen one to the flow.
`meta:write-a-skill` scaffolds a skill with its eval and registration
(`skills/write-a-skill/scripts/scaffold.sh`); `meta:retro` reads `.flow/lessons.jsonl` and
routes each lesson to a durable home, as a PR to this repo when a rule or skill changes.
`meta:map` shows `docs/map.html`, the generated map of every plugin, skill, agent and hook
(`tools/lib/map.py`; stale when the sources change, so `tools/lint.sh` fails until regenerated).
Tests: `plugins/meta/tests/run.sh`. Evals: `tools/eval.sh craft`, `tools/eval.sh meta`.

## Install
Claude: `claude plugin marketplace add /work/brain` once, then `claude plugin install <plugin>@brain-plugins`.
Codex: `codex plugin marketplace add /work/brain` once, then `codex plugin add <plugin>@brain-plugins`.
A project enables them in `.claude/settings.json` (`enabledPlugins`) and `.codex/config.toml` (`[plugins]`).
