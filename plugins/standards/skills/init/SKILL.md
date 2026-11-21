---
name: init
description: Install or refresh the coding standards in this repository, at project scope (the default; the rules block in AGENTS.md, path-scoped Claude rules and the Codex agents in the project) or at machine scope (--scope machine; those three in the user's Claude and Codex folders, for every project on the machine, and no tracked file changed). Also writes the full rule text and the testing guide under .standards/, the hook copies and the git hook wiring, the project's skills and rules links and its rendered roster; then fills the gaps (commands, the testing guide, gates) with the owner from the project-advisor's recommendations. Use when a repo adopts the standards plugin, after a plugin update, when the user asks to check whether the standards are up to date (init --check is the one drift check), or asks where a new test level, gate, reviewer or rule belongs (init <the ask>).
disable-model-invocation: true
---

Install the standards plugin into the current repository, or refresh it after a plugin update.
With an argument that is not a flag (`init add a determinism gate`), skip to **Asks** below.

## Steps

1. **Run the installer** from the repository root:
   ```
   "<plugin root>/skills/init/scripts/init.sh"
   ```
   The plugin root is the directory that holds this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude;
   on Codex, the plugin's install path, which `codex plugin list` prints). To only report drift,
   hand edits and gaps, add `--check`. If it refuses a file edited by hand, do not add `--force`
   for the owner: show the refusal and ask. The edit belongs in the plugin source.
   Add `--scope machine` when the project must not change: rules and agents go to your user
   folders and apply to every project on this machine. On a first install (no
   `.standards/stamp` and no `--scope` in the ask), ask the owner which scope before running it:
   project (the default, committed for the team) or machine. Later runs keep the scope the stamp
   remembers; `--scope` switches it. A switch to machine scope names the block, rules and agents
   an earlier project-scope install left in the project, and never removes them.
2. **Read what it printed.** The script lists every file it wrote, the `Gaps` (values the hooks
   and the verifier cannot run without, and the guide's placeholders) and what the owner must do
   next.
3. **When it listed gaps, or the guide's levels table has an empty row, spawn the
   `project-advisor`** with the gap lines (if any), the config and the guide paths. An empty row
   is one with the slot `nothing` or the command `not set up`; a table with no slot column, or
   with no smoke, property-based or runtime evidence row, counts too (an older guide passes
   `--check` without them). It reads the repository and returns one recommendation per gap and
   per empty row with its evidence and a confidence word. Do not research them yourself. When
   the `project-advisor` is not available, which is usual in the session that installed the
   plugin (the host has not loaded its agents yet), spawn a general-purpose agent instead and
   give it the advisor's brief: the body of `<plugin root>/agents/project-advisor.md` on Claude,
   the `developer_instructions` of `<plugin root>/codex-agents/project-advisor.toml` on Codex,
   followed by the same gap lines, config and guide paths. Say in the report that a general
   agent stood in. In a session that cannot spawn agents at all, list the gaps and empty rows
   without recommendations and say the advisor did not run.
4. **End with one report**, per W-07, with no copy of the installer's output: the files
   changed, grouped by folder; what the owner must do by hand, in one list (review
   `.standards/config.json` on a first install, the `init: note:` lines, the Codex `/hooks`
   trust); that the changes are uncommitted (in machine scope there is nothing to commit, unless a
   switch from project scope rewrote a committed `.standards/`);
   then the gaps as one numbered list, one line each:
   the target (file and key or section, the file named on every line even when the line above
   names the same one), the advisor's value, its evidence and confidence, so the owner answers
   "1 yes, 2 no, 3 use X" or "all". A gap with no evidence gets one question, nothing more: no
   second question, no example value, no default the owner could accept with "all". Report only
   the gaps the installer listed, then the advisor's slot for each empty row of the guide's
   levels table.
5. **On a first install, add one more numbered item to that list**: "Doc comments are allowed
   above `public` declarations and on `interface` and `enum` members (`comments.doc_inside`).
   Add more container kinds, such as `class`, `struct` or `record`, or remove one?" An existing
   config without the key keeps the same default; say so and do not add it unasked. Never hold
   the report back for the answers.
6. **Apply the answers.** Write each accepted value where the list said: the config keys in
   `.standards/config.json`, the guide lines in `.standards/testing-guide.md` (replace the
   `_fill in_` placeholder, keep the section), a slot in its levels row and under the key the
   slot names. A rejected gap stays open and `init --check` keeps reporting it; say so. Then run
   `init --check` and show its last line.

## Asks

`init <what the owner wants>` ("add a mutation run", "a gate that forbids update-golden
outside a closeout", "a physics reviewer for src/Physics/**"): spawn the `project-advisor`
with the ask instead of gap lines. Its "Where things go" table maps the ask to the file and
key; present its recommendation with the evidence, apply it on the owner's yes, run
`init --check`. Something that belongs to the flow plugin (`.flow/config.yaml`) is named as
such and left to `flow:init`.

## What the installer writes

| Target | Content | Re-run behaviour |
|---|---|---|
| `.standards/config.json` | format, build, test and mutation commands, protected files, hot paths, gates, project links, roster and eval cases folder (`project.evals`), the rules the project relaxes (`rules.relaxed`, `rules.judgement`) | written once, never overwritten; empty `build`, `test`, `languages` or a language without `format` is a gap, and so is a bad id in `rules` |
| `.standards/testing-guide.md` | levels with the slot that runs each and its command, fixtures, declared exceptions, the hand-test list | written once, never overwritten; a `_fill in_` placeholder is a gap |
| `.standards/rules/*.md` | the full rule text with ids and reasons, without the `rules.relaxed` rules and with the `rules.judgement` ones tagged judgement | replaced |
| `AGENTS.md` (and a separate `CLAUDE.md`) | one block between `<!-- standards:begin vX.Y.Z -->` and `<!-- standards:end -->`: hard rules, signals, `## Code Review Rules`; with `rules.relaxed` or `rules.judgement` set, those ids leave the hard rules and signals for a `## Waived by this project` and a `## Judgement in this project` list | the block is replaced, nothing outside it is touched |
| `.claude/rules/standards-*.md` | one file per section with `paths:` for the configured source extensions, filtered like `.standards/rules/*.md` | replaced |
| `.codex/agents/*.toml` | the plugin's review agents and the advisor for Codex | replaced |
| `.standards/hooks/` | the gate scripts and the git hooks (`git/pre-commit`, `git/commit-msg`, `git/pre-push`) for human commits; `check-range.sh` for CI | copies replaced |
| git hook wiring | a project with its own `.githooks/` gets one appended call per hook (pre-commit, commit-msg, pre-push) and `core.hooksPath .githooks`; a project without one gets `core.hooksPath .standards/hooks/git` and no new folder | the call is appended once; `core.hooksPath` is set only when unset (local config, so every clone runs `init` once) and never over live hooks: when `.git/hooks` holds an executable hook (not `*.sample`) git would stop running, init names it and sets nothing |
| `.claude/skills`, `.agents/skills` | relative links to `project.skills` from the config, when set | fixed when they point elsewhere; a real folder in the way is reported |
| `.claude/rules/project` | a relative link to `project.rules`, when set | same |
| `.claude/agents/<name>.md`, `.codex/agents/<name>.toml` | the project roster (`project.roster`) rendered with the plugin's templates and defaults (`templates/agents/`) | replaced; an agent dropped from the roster is removed |
| `.standards/evals/run.sh`, `.standards/evals/.gitignore` | with a project roster: the runner for the project's agent evals (cases in `project.evals`, see [AGENT-EVALS.md](AGENT-EVALS.md)) and `results/` ignored | replaced; removed when the roster goes |
| `.standards/stamp` | a hash of the plugin's install set, then one hash per copy above | rewritten; commit it (project scope) |
| machine scope: `$CLAUDE_CONFIG_DIR/CLAUDE.md`, `$CODEX_HOME/AGENTS.md` (default `~/.claude`, `~/.codex`) | the block, instead of `AGENTS.md` and `CLAUDE.md` | the block is replaced, the owner's text around it stays |
| machine scope: `$CLAUDE_CONFIG_DIR/rules/standards-*.md`, `$CODEX_HOME/agents/*.toml` | the Claude rules with `paths: "**/*"` and the Codex agents, instead of the project's | replaced |
| machine scope: git hook wiring | one call per hook (pre-commit, commit-msg, pre-push) in the clone's own hooks folder, after the lines already there, naming the main worktree's absolute path; a missing hook is created | placed once and rewritten when the clone moves; `core.hooksPath` and `.githooks/` are never touched, and with `core.hooksPath` set init prints the line to add there |
| machine scope: `.git/info/exclude` | a `# standards:begin` / `# standards:end` block: `/.standards` and the project-level paths init wrote (roster agents, skills and rules links) | the block is replaced, the lines around it stay |
| machine scope: `.standards` in each linked worktree | a link to the main worktree's `.standards/` | added when missing, fixed when it points elsewhere; a real folder there is left, with a note |
| machine scope: `worktree_setup` in `.flow/config.yaml` | when flow is installed, one item that links `.standards` in each worktree flow adds | added once under a plain `worktree_setup:` line in an untracked config; a tracked config or any other shape gets the item printed for the owner |

**Relaxed rules.** `rules.relaxed` in `.standards/config.json` lists the rule ids the project
waives: no copy or block line names them and no reviewer raises them. `rules.judgement` lists the
hard or signal rule ids it grades as [judgement]: P2 at most, a breach declared per U-02. `init`
renders the rule copies and the block from both lists, so re-run it after editing them (the
session-start nudge does not see the edit). An unknown id, a usage rule, a `judgement` id that is
not hard or signal, an id in both lists, or an id a plugin hook enforces (C-01, C-02, W-01, L-03:
the lists do not reach the hooks; the gap names the hook and its switch) is a gap.
At machine scope the user-folder block and Claude rules are shared by every project, so they keep
the plugin's text and init says so; `.standards/rules/` still takes the lists.

**Gaps.** `init` ends with a `Gaps` list when the config or the guide cannot do its job yet;
`init --check` prints them as `init: gap:` lines and exits 1 until they are filled, so one
command answers "is this project set up". The session-start nudge does not look at gaps.

**Machine scope.** The stamp remembers the scope (a stamped absolute path means machine), so
`init` and `init --check` without `--scope` keep it. It works on the main worktree even when run
from a linked one, needs `CLAUDE_CONFIG_DIR` and `CODEX_HOME` to be absolute when set, and the
user-folder block, rules and agents apply to every project on this machine. When
`$CODEX_HOME/AGENTS.override.md` is not empty, Codex reads it instead of `AGENTS.md`; `init`
prints a note.

The agent hosts run the hooks from the plugin itself (`hooks/hooks.json`, the same file on both
hosts); the copies serve git and CI. `init` writes no hook entry into `.claude/settings.json` or
`.codex/hooks.json`: hooks merge without deduplication, so an entry there would run every gate
twice, and `init --check` reports one as stale. What a project needs is the plugin enabled at
project scope (`claude plugin install standards@<marketplace> --scope project`; Codex:
`[plugins."standards@<marketplace>"] enabled = true` in `.codex/config.toml`); `init` prints a
note while that is missing. Machine scope prints the same project-scope notes; to leave the
project's files as they are, enable the plugin for your user instead (`claude plugin install
standards@<marketplace>`; Codex: the same table in `$CODEX_HOME/config.toml`).
On Codex the plugin hooks run only after a one-time `/hooks` trust,
again after every plugin update. The plugin writes only under `.standards/` plus the host paths
above; it never creates `docs/` or `.githooks/`.

**The project's own gates** live in `.standards/config.json` as `gates`, not as scripts:

```json
"gates": [
  {"name": "build", "command": "dotnet build src/App.sln --nologo -v q",
   "paths": ["src/**", ".editorconfig", "Directory.Build.*"], "when": ["commit", "ci"]},
  {"name": "hash-pause", "command": "tools/check-hashes.sh", "marker": "[closeout #218]"},
  {"name": "pause", "forbid": ["update-golden"], "marker": "[closeout #218]"}
]
```

A command gate runs its command from the repo root before a commit when a committed file matches
one of its globs (no `paths`: always), before a push (`"push"`, no path filter) and per commit in
CI (`"ci"`); `when` defaults to `["commit"]`; a failing command blocks. The command sees two
environment variables: `STANDARDS_COMMIT_MESSAGE` (the message of the commit, empty before a
push) and `STANDARDS_STAGE` (`commit`, `push` or `ci`). A command gate with a `marker` is skipped
by a commit whose message carries it, so an approved commit goes through. A forbid gate blocks
an agent command that runs one of its texts unless the command or its commit message carries
the marker. The text must stand as a word in the part of the command that runs. A heredoc body,
a comment, a commit message, a grep pattern, an `echo` or quoted prose that only names it does
not trip the gate. A one-word quoted argument (`make "update-golden"`) and the argument of
`sh -c`, `bash -c` and `eval` do. The same hook (`check-gates.sh`) serves the
agent hosts, the git hooks and `check-range.sh`. The commit-message markers (`[config]`,
`[allow-docs]`, `[why-comment]`, a gate's marker) reach the git hooks through `commit-msg`,
which git hands the real message. That is also where a command gate with a marker runs: the
`pre-commit` hook has no message yet and runs the gates without one. An agent's commit runs each
gate once: when the agent hook passes the formatter or the gates for a plain `git commit` of the
index, it records that index tree in the git dir, and git's own hooks skip the same tree for ten
minutes. A `git add` in the same command, `-a` or a pathspec changes the index, so git's hooks
run the gates again.

**Agent evals.** `.standards/evals/run.sh` runs the cases in `project.evals` (one folder per
case, the `claude plugin eval` format) against the rendered `.claude/agents/`; without the key it
prints how to add one and exits 0. The cases are the project's own; [AGENT-EVALS.md](AGENT-EVALS.md)
shows how to write one. Each run costs money, so CI never runs it.

**Mutation** is `mutation` in `.standards/config.json`. An empty string turns it off: verify
reports a skipped check, the test reviewer and T-04 do not ask for it. With `{files}` in the
command, verify runs it on the changed source files only (like a format command) and skips it
when none changed; without it the command runs as written. It is a signal, never a fail (T-05).

**CI** calls the plugin's composite action in one step, after a checkout with `fetch-depth: 0`
and the toolchain setup: `uses: FilipposKaragiannis/brain/plugins/standards/action@main`. It runs
`check-range.sh` over the branch's commits, each against its own message (`check-config`,
`check-comments` and the `ci` gates; the `gates` input changes the list). Before v0.2.0 the rule
text and the guide lived under `docs/`: `init` removes an old rule copy it wrote, moves the old
guide when it is still the plugin's, reports anything else, and `--check` flags the old files as
stale.

**The guard.** Before replacing a copy, `init` compares it with the hash in the stamp. A copy
that differs from what `init` last wrote was edited by hand: `init` refuses it (exit 1, the rest
is installed) and `--force` replaces it. A project installed before the stamp existed is
replaced once, then stamped.

**The nudge.** The plugin's `SessionStart` hook compares the stamp's first line with the plugin
on disk and, when they differ, prints the drift and asks for `init`. It is silent in a project
without `.standards/config.json` and it does not look for hand edits or gaps; `init --check`
does.

## Never

- Never edit `.standards/config.json` or the testing guide beyond the owner's answers in step 6
  or an accepted ask. Suggest other changes and stop.
- Never commit. The owner reviews the diff.
