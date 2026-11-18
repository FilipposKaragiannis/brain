bump: minor

- `init --scope machine` installs the standards into one clone without changing a tracked file.
  The rules block goes to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` (`CLAUDE_CONFIG_DIR` and
  `CODEX_HOME` move them), the Claude rules to `~/.claude/rules/` with `paths: "**/*"` and the
  Codex agents to `~/.codex/agents/`, so they apply to every project on the machine. The git hook
  calls are chained into the clone's own hooks folder after the lines already there, and the
  clone's outputs are listed in a marked block in `.git/info/exclude`. The stamp remembers the
  scope, so `init` and `init --check` keep it; `--check` is clean. An earlier project-scope
  install is named, never removed.
- init no longer points `core.hooksPath` away from live hooks: when `.git/hooks` holds an
  executable hook (not `*.sample`) that git would stop running, init names it, sets nothing and
  says how to call the standards hooks from it, or to use `--scope machine`. `--check` reports it
  as a note, not drift. This changes the default for a clone with its own hooks, such as Git LFS.
- In machine scope each linked worktree gets a `.standards` link to the main worktree's, so the
  git hooks, the gates and the session hooks find the config there. When flow is installed, init
  adds the line that makes the link to `worktree_setup` in `.flow/config.yaml`.
