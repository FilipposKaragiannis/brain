# standards

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
