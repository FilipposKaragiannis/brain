---
name: init
description: Install or refresh the coding standards in this repository. Writes the rules block into AGENTS.md, the full rule text and the testing guide under .standards/, path-scoped Claude rules, the Codex agents, the hook copies and the git hook wiring, the project's skills and rules links and its rendered roster; then fills the gaps (commands, the testing guide, gates) with the owner from the project-advisor's recommendations. Use when a repo adopts the standards plugin, after a plugin update, when the user asks to check whether the standards are up to date (init --check is the one drift check), or asks where a new test level, gate, reviewer or rule belongs (init <the ask>).
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
2. **Read what it printed.** The script lists every file it wrote, the `Gaps` (values the hooks
   and the verifier cannot run without, and the guide's placeholders) and what the owner must do
   next.
3. **When it listed gaps, spawn the `project-advisor`** with the gap lines, the config and the
   guide paths. It reads the repository and returns one recommendation per gap with its evidence
   and a confidence word. Do not research the gaps yourself. In a session that cannot spawn
   agents, list the gaps without recommendations and say the advisor did not run.
4. **Report once**, per W-07, in one short message (about ten lines plus the gap list, no step
   narration, no copy of the installer's output): the files changed, grouped by folder; what the
   owner must do by hand, in one list (review `.standards/config.json` on a first install, the
   `init: note:` lines, the Codex `/hooks` trust); that the changes are uncommitted; then the
   gaps as one numbered list, one line each: the target (file and key or section), the advisor's
   value, its evidence and confidence, so the owner answers "1 yes, 2 no, 3 use X" or "all". A
   gap with no evidence gets the one question to ask, nothing more. Report only the gaps the
   installer listed.
5. **On a first install, add one more numbered item to that list**: "Doc comments are allowed
   above `public` declarations and on `interface` and `enum` members (`comments.doc_inside`).
   Add more container kinds, such as `class`, `struct` or `record`, or remove one?" An existing
   config without the key keeps the same default; say so and do not add it unasked. Never hold
   the report back for the answers.
6. **Apply the answers.** Write each accepted value where the list said: the config keys in
   `.standards/config.json`, the guide lines in `.standards/testing-guide.md` (replace the
   `_fill in_` placeholder, keep the section). A rejected gap stays open and `init --check`
   keeps reporting it; say so. Then run `init --check` and show its last line.

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
| `.standards/config.json` | format, build, test and mutation commands, protected files, hot paths, gates, project links and roster | written once, never overwritten; empty `build`, `test`, `languages` or a language without `format` is a gap |
| `.standards/testing-guide.md` | levels and commands, fixtures, declared exceptions, the hand-test list | written once, never overwritten; a `_fill in_` placeholder is a gap |
| `.standards/rules/*.md` | the full rule text with ids and reasons | replaced |
| `AGENTS.md` (and a separate `CLAUDE.md`) | one block between `<!-- standards:begin vX.Y.Z -->` and `<!-- standards:end -->`: hard rules, signals, `## Code Review Rules` | the block is replaced, nothing outside it is touched |
| `.claude/rules/standards-*.md` | one file per section with `paths:` for the configured source extensions | replaced |
| `.codex/agents/*.toml` | the plugin's review agents and the advisor for Codex | replaced |
| `.standards/hooks/` | the gate scripts and the git hooks (`git/pre-commit`, `git/commit-msg`, `git/pre-push`) for human commits; `check-range.sh` for CI | copies replaced |
| git hook wiring | a project with its own `.githooks/` gets one appended call per hook (pre-commit, commit-msg, pre-push) and `core.hooksPath .githooks`; a project without one gets `core.hooksPath .standards/hooks/git` and no new folder | the call is appended once; `core.hooksPath` is set only when unset (local config, so every clone runs `init` once) |
| `.claude/skills`, `.agents/skills` | relative links to `project.skills` from the config, when set | fixed when they point elsewhere; a real folder in the way is reported |
| `.claude/rules/project` | a relative link to `project.rules`, when set | same |
| `.claude/agents/<name>.md`, `.codex/agents/<name>.toml` | the project roster (`project.roster`) rendered with the plugin's templates and defaults (`templates/agents/`) | replaced; an agent dropped from the roster is removed |
| `.standards/stamp` | a hash of the plugin's install set, then one hash per copy above | rewritten; commit it |

**Gaps.** `init` ends with a `Gaps` list when the config or the guide cannot do its job yet;
`init --check` prints them as `init: gap:` lines and exits 1 until they are filled, so one
command answers "is this project set up". The session-start nudge does not look at gaps.

The agent hosts run the hooks from the plugin itself (`hooks/hooks.json`, the same file on both
hosts); the copies serve git and CI. `init` writes no hook entry into `.claude/settings.json` or
`.codex/hooks.json`: hooks merge without deduplication, so an entry there would run every gate
twice, and `init --check` reports one as stale. What a project needs is the plugin enabled at
project scope (`claude plugin install standards@<marketplace> --scope project`; Codex:
`[plugins."standards@<marketplace>"] enabled = true` in `.codex/config.toml`); `init` prints a
note while that is missing. On Codex the plugin hooks run only after a one-time `/hooks` trust,
again after every plugin update. The plugin writes only under `.standards/` plus the host paths
above; it never creates `docs/` or `.githooks/`.

**The project's own gates** live in `.standards/config.json` as `gates`, not as scripts:

```json
"gates": [
  {"name": "build", "command": "dotnet build src/App.sln --nologo -v q",
   "paths": ["src/**", ".editorconfig", "Directory.Build.*"], "when": ["commit", "ci"]},
  {"name": "pause", "forbid": ["update-golden"], "marker": "[closeout #218]"}
]
```

A command gate runs its command from the repo root before a commit when a committed file matches
one of its globs (no `paths`: always), before a push (`"push"`, no path filter) and per commit in
CI (`"ci"`); `when` defaults to `["commit"]`; a failing command blocks. A forbid gate blocks any
agent command containing one of its texts unless the command or its commit message carries the
marker. The same hook (`check-gates.sh`) serves the agent hosts, the git hooks and
`check-range.sh`. The commit-message markers (`[config]`, `[allow-docs]`, `[why-comment]`, a
gate's marker) reach the git hooks through `commit-msg`, which git hands the real message.

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
