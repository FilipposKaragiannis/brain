# standards

## 1.9.0 (2026-11-22)

- The formatter hook reads `{files}` through the same shared helper as flow's verify, so the two
  cannot drift, and a file name is never read as shell. `{files}` is accepted in two forms: as an
  unquoted word of its own in the command, or as an unquoted word of its own in the script of a
  `sh -c` or `bash -c` that starts a command. A word ends at a blank or at one of `; & | < > ( )`
  and a newline. Every other placement is refused, as a failed format check whose message names
  the accepted forms. To pass the names into any other construct, write `"$@"` there and put
  `{files}` as the last word of the command, as in `sh -c '... "$@"' sh {files}`. The shell, `-c`
  and the script are read as words split by any run of spaces and tabs.
- The rule generator turns every `## Appendix <letter>. <Language>` section of the coding
  standards into its own rule file, indexes its ids as conventions and lists each appendix with
  the file types its `Files:` line names in `rules/appendices.json`. The compact block names every
  appendix.
- Two new appendices: B. Shell (SH-01 to SH-13) and C. Python (PY-01 to PY-18). PY-02, PY-06,
  PY-07 and PY-10 carry the suggested readings of the type checker, S-13, D-09 and pytest, which
  the owner has still to confirm.
- `init` installs a language appendix only when a configured language shares a file extension
  with it, and its Claude rule loads for that language's files alone, so a `.sh` read no longer
  loads the C# appendix. An appendix the project stops using is removed when init wrote it. At
  machine scope every appendix installs, each for its own extensions. The drift hash covers every
  appendix and the appendix list.
- SH-11 no longer asks for a contract line above each function. A script's header says what the
  script is for and what it takes; no comment above or inside a function says what the code does,
  names carry the meaning, and a comment stays only for a why the code cannot show.
- At project scope the block init installs names only the appendix files it installs for the
  configured languages, in the plugin's order, and no language sentence when none has an appendix.
  It used to name every appendix, so a shell project's block pointed at a `csharp.md` it did not
  have. The machine-scope block still names every appendix, as every one installs there.
- The formatter, comment, gate and protected-file hooks read staged file names NUL-separated from
  git and treat each as data. A name with a space, a quote, `$( )`, a backtick, a newline or a
  leading dash reaches the formatter as one argument and can no longer run a command.
- `{files}` in a `format` command stands for `"$@"`: the command runs as `sh -c <command> sh
  <names>`. A `{files}` inside quotes, as in `sh -c 'for f in {files}; ...'`, still sees the names:
  each is backslash-escaped for the nested shell. A name with a newline in such a command blocks.
- A failing formatter's report lists the files it was given.
- The comment hook takes file names from git, never from the diff text, so a name with a tab,
  carriage return, newline, backslash, quote or non-ASCII letter keeps its own content lookup. It
  reads staged content without following symlinks, and blocks when it cannot read the diff.

## 1.8.0 (2026-11-21)

- The testing guide's levels table names the slot that runs each level: the test command, the
  mutation command, a verify gate, a commit gate, a scheduled check or nothing. It gains rows for
  smoke, property-based and runtime evidence checks, each `not set up` until the project has one.
- `init` spawns the `project-advisor` for an empty levels row too, and for a guide written from
  the older table, which still passes `init --check`. The advisor recommends a slot and a command
  for each such row, and `init` writes an accepted one into the row and under the slot's key.

## 1.7.0 (2026-11-20)

- A project gate takes `forbid_run`: it blocks a command that starts one of the programs named,
  as written or by a longer path, and through a shell, `env`, `exec`, `nohup`, `nice` or
  `timeout` too. A command that only names the path (`git add`, `sed`, `grep`, `sh -n`) passes.
  `forbid` matches a text anywhere in the command, which blocks reading or staging a script
  whose path it names; it stays for a verb passed as an argument.
- `build` and `test` in `.standards/config.json` take a map `{command, paths}`, and `test` a list
  of `{name, command, paths}`: the flow verifier then runs a command only when a changed file is
  under its paths. The pre-push hook runs the build's command in either form, `init` names a
  malformed entry among the gaps, and the config's `_readme` says how to scope a command.
- The testing guide template has a place for the command that runs one test or one group alone,
  which the implement and test steps use instead of the whole test command.

## 1.6.0 (2026-11-18)

- `init --scope machine` installs the standards into one clone without changing a tracked file.
  The rules block goes to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` (`CLAUDE_CONFIG_DIR` and
  `CODEX_HOME` move them), the Claude rules to `~/.claude/rules/` with `paths: "**/*"` and the
  Codex agents to `~/.codex/agents/`, so they apply to every project on the machine. The git hook
  calls are chained into the clone's own hooks folder after the lines already there, and the
  clone's outputs are listed in a marked block in `.git/info/exclude`. The stamp remembers the
  scope, so `init` and `init --check` keep it; `--check` is clean. An earlier project-scope
  install is named, never removed.
  The user-folder block and Claude rules keep the plugin's text, because every project shares
  them, so a project's `rules.relaxed` and `rules.judgement` reach only its `.standards/rules/`.
- init no longer points `core.hooksPath` away from live hooks: when `.git/hooks` holds an
  executable hook (not `*.sample`) that git would stop running, init names it, sets nothing and
  says how to call the standards hooks from it, or to use `--scope machine`. `--check` reports it
  as a note, not drift. This changes the default for a clone with its own hooks, such as Git LFS.
- In machine scope each linked worktree gets a `.standards` link to the main worktree's, so the
  git hooks, the gates and the session hooks find the config there. When flow is installed, init
  adds the line that makes the link to `worktree_setup` in `.flow/config.yaml`, or prints it for
  the owner when that file is tracked.
- A project relaxes the rules that clash with its house style in `.standards/config.json`:
  `rules.relaxed` lists the rule ids it waives, `rules.judgement` the hard or signal rule ids it
  grades as [judgement]. `init` drops a waived rule's line from `.standards/rules/` and
  `.claude/rules/standards-*.md`, tags a demoted one `[judgement, relaxed from hard by this
  project]`, and moves both out of the block's hard rules and signals into a
  `## Waived by this project` and a `## Judgement in this project` list. Re-run `init` after
  editing the lists. A project without them gets the same files as before.
- An unknown id, a usage rule, a `judgement` id that is not hard or signal, an id in both lists,
  or an id a plugin hook enforces (C-01, C-02, W-01, L-03; the gap names the hook and its switch)
  is an `init` gap, so `init --check` exits 1 until it is fixed.
- The review skill and the standards, test and performance reviewers never raise a waived rule
  and grade a demoted one P2 at most. The project-advisor routes a rule the house style breaks on
  purpose to the two lists, and new configs carry them empty.

## 1.5.1 (2026-11-17)

- The spec-reviewer grades an acceptance check the diff must carry and the reports call
  unproven as a partial requirement, leaves a check a later step proves as pending, and for a
  bug treats the Problem steps as a requirement the reproducing test must show.

## 1.5.0 (2026-11-16)

- init asks one plain question for a gap the repository gives no evidence for: no second
  question, no example value, no default the owner could accept with "all".
- A command gate runs without git's repository variables (`GIT_DIR`, `GIT_INDEX_FILE`,
  `GIT_WORK_TREE` and the rest of `git rev-parse --local-env-vars`). Git exports them to its
  hooks, so a gate that ran tests from the pre-commit hook aimed the tests' git at the repository
  being committed: a test's `git init --bare` made the main checkout bare and its `git config`
  wrote the test identity into it. The gate still runs from the repository root, where git finds
  the repository on its own. The hooks' own suite now runs in the repository's test sandbox.
- W-07 keeps the one report at the end but no longer bans notes on the way: during long work a
  one-line note on the current step is welcome. Current models read the old "no narration" as
  silence through long tasks.
- The reviewers and the project advisor lose their word caps ("under 400 words"); the review
  skill drops its per-reviewer cap. The findings-only shape keeps the reports tight, and current
  models cut facts to fit a number.
- The init skill ends with one report and drops "about ten lines, no step narration". Each gap
  line names its file, even when the line above names the same one.

## 1.4.2 (2026-11-15)

- U-05 says a renamed line is touched code, and that a U-02 declaration covers a [judgement]
  rule only: a [hard] rule on a moved line is met. It used to offer a declaration for any rule.
- The standards reviewer grades a declared [hard] breach P0, not P2, and grades moved, copied and
  renamed lines like new ones.

## 1.4.1 (2026-11-11)

- The Codex reviewers follow the roster's new model map: the spec, security and performance
  reviewers and the project advisor run as `gpt-6.1-sol`, the standards and test reviewers as
  `gpt-6.1-terra`.

## 1.4.0 (2026-11-08)

- New hard rule M-08 No hidden side effects: a method changes only what its name says. A method
  that decides, checks or computes returns its result and the caller assigns it; it writes
  through a parameter only when its name says it changes that argument. CS-13 says the same for
  C# `ref`. A method named for a decision had its `in` velocity turned `ref` and overwritten; the
  implementer copied the file's habit and four reviewers passed it, because no rule named it.
- The standards-reviewer brief checks every signature that now lets a method write an argument
  it only read before against M-08.

## 1.3.0 (2026-11-01)

- W-01 gets a machine check. The git `commit-msg` hook runs `check-subject.sh` on the message
  file and blocks a subject that is not `type(scope): summary`. Git's Merge, Revert, fixup!,
  squash! and amend! subjects pass. A reviewer caught a gate instruction used as a subject.
- U-05 says moved code is touched code: a block moved into a new file, type or helper meets the
  rules or carries a U-02 declaration. Three review blockers in one week came from moved code.

## 1.2.3 (2026-10-25)

- `json_string` (the shared JSON helper in `hooks/json.sh`) no longer prints nothing for text
  that is not UTF-8 when jq is missing: the python3 fallback replaces such bytes with U+FFFD, so
  a hook's JSON stays valid.

## 1.2.2 (2026-10-19)

- The eval runner puts git and python3 wrappers first on PATH, from `.standards/evals/.bin`
  (git-ignored), as `tools/eval.sh` does. On macOS `/usr/bin/git` and `/usr/bin/python3` ask
  xcrun, which cannot write its cache in the sandbox, so git failed ("Failed to locate 'git'")
  and python3 printed errors. Each wrapper calls the binary `xcrun --find` names; without xcrun
  there is none. `init` removes `.bin` with the runner.

## 1.2.1 (2026-10-18)

- The eval runner copies the cases into its wrapper instead of linking them: a real run refused
  the link ("an eval-directory link that points outside the plugin"). The copy carries
  `.repo-root`, the repo's path, because a scaffold script runs from the copy without the
  runner's environment; AGENT-EVALS.md shows the read and the `execution:` block its example
  case was missing.

## 1.2.0 (2026-10-18)

- `init` installs `.standards/evals/run.sh` (and a `.gitignore` for its `results/`) in a project
  with a roster (`project.roster`), stamped and guarded like the other copies, and removes it
  when the roster goes. It runs the project's own agent evals with `claude plugin eval`: the
  cases in the new `project.evals` folder, against copies of `.claude/agents/*.md` in a
  throwaway wrapper plugin whose `cases` links to the real folder. Without `project.evals` it
  prints how to add cases and exits 0. Claude only; costs money, never in CI.
- `skills/init/AGENT-EVALS.md`: how to write a case (layout, a planted bug, the three graders).

## 1.1.0 (2026-10-11)

- `init` no longer leaves its call dead in a project's own `.githooks/*`. It puts the call before
  a trailing top-level `exit`, and moves a call that an earlier init left after one.
  `init --check` reports such a call as drift ("is after an exit and never runs").
- Command gates honour `marker`. A commit whose message carries it skips the gate. The git
  `pre-commit` hook has no message, so it runs only the gates without a marker
  (`STANDARDS_GATES=unmarked`); `commit-msg` runs the marked ones (`=marked`); the agent hosts
  and CI run all of them against the message of the commit.
- The gate command gets `STANDARDS_COMMIT_MESSAGE` and `STANDARDS_STAGE` in its environment, so
  a script can check the staged files against the message itself.
- Forbid gates match the text as a word in the part of the command that runs. A heredoc body, a
  comment, a commit message or an `echo` that names a paused verb no longer blocks. The quoted
  argument of `sh -c`, `bash -c` and `eval`, and `$( )` inside double quotes, still count.
  `update-golden-all` is not `update-golden`; `./update-golden.sh` is. A one-word quoted argument
  (`make "update-golden"`) still counts; quoted prose, a `-m`/`-e`/`--grep` value and the
  arguments of `echo`, `printf`, `grep`, `rg`, `sed`, `awk` and `cat` do not.
- An agent's commit runs the formatter and the gates once, not twice. The agent hook records the
  index tree it passed (in the git dir); git's `pre-commit` and `commit-msg` skip that same tree
  for ten minutes. Any other index runs them again.
- Mutation: an empty `mutation` is the supported off switch. T-04 says so and the test reviewer
  never reports a missing mutation run. `mutation` may carry `{files}`; the flow verifier then
  runs it on the changed source files only.
- `init` falls back to a general agent fed the project-advisor brief when the plugin's agents are
  not loaded yet (the session that installed the plugin).

## 1.0.0 (2026-10-11)

First stable release: the config keys and the hook contracts are kept from here on.


- Gaps: `init` ends with the values the hooks and the verifier cannot run without (`build`,
  `test`, `languages`, a language without `format`) and the testing guide's `_fill in_`
  placeholders; `init --check` prints them as `init: gap:` and exits 1 until they are filled.
- `project-advisor`: a read-only agent that reads the repository and recommends a value per gap
  with its evidence and a confidence word, and maps an owner's ask ("add a determinism gate") to
  the file and key. The init skill spawns it on gaps and on `init <ask>`, and applies what the
  owner accepts.

## 0.3.0 (2026-10-11)

- Project gates as config: `gates` in `.standards/config.json` (`{name, command, paths, when}`
  and `{name, forbid, marker}`), run by the new `check-gates.sh` from the plugin hook, the git
  hooks and CI. A project deletes its gate scripts.
- Git hooks: `init` owns `pre-commit` (formatter, command gates), the new `commit-msg` (the
  marker-aware gates with the real message) and `pre-push` (build, push gates); a project's own
  `.githooks/` gets one appended call per hook, with the hook arguments passed on.
- Host wiring: both hosts run the gates from the plugin's `hooks/hooks.json`; `init` writes no
  settings entry and `init --check` flags a project entry that would run the gates twice, and
  notes a missing project-scope enablement.
- `project.skills` and `project.rules` in the config: `init` creates and checks the relative
  links (`.claude/skills`, `.agents/skills`, `.claude/rules/project`).
- `project.roster`: `init` renders the project roster into `.claude/agents/` and
  `.codex/agents/` with the plugin's templates and defaults (`templates/agents/`,
  `render_agents.py`, shared with the marketplace generator); `paths` per reviewer makes the
  review skill spawn it when the diff touches them; `init --check` flags stale output.
- CI: `check-range.sh` runs the commit gates per commit over a range, each against its own
  message, and the composite action `plugins/standards/action` calls it in one step.
- `check-config.sh`: protected globs are no longer expanded against the working tree.

## 0.2.0 (2026-10-11)

- The plugin writes only under `.standards/`: the rule text moved from `docs/standards/` to
  `.standards/rules/`, the testing guide from `docs/testing-guide.md` to
  `.standards/testing-guide.md`. `init` removes an old rule copy it wrote and moves the old guide;
  `init --check` flags both as stale. The block text and every agent cite the new paths.
- Git hooks: `init` no longer creates `.githooks/`. A project with its own `.githooks/` gets one
  appended call per hook; a project without one gets `core.hooksPath` pointed at
  `.standards/hooks/git`.
- `check-comments.sh`: a doc comment is allowed on any declaration inside an `interface` or
  `enum` (`comments.doc_inside` in the config; the same default applies when the key is absent,
  `[]` turns it off), and attribute lines between the doc and its declaration are skipped. The
  init skill asks the owner on a first install whether to add container kinds.
- `init` writes `.standards/stamp`, refuses to replace a copy edited by hand (`--force`), and a
  `SessionStart` hook asks for `init` when the stamp is behind the plugin.
- The testing guide is written with python, so a test command containing `&` survives.

## 0.1.0 (2026-10-10)

- First release of the rework: rules with ids, the block, the hooks, the two-axis review.
