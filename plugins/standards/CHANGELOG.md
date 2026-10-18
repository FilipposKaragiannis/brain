# standards

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
