bump: minor

- `build` and `test` in `.standards/config.json` take a map `{command, paths}`, and `test` a list
  of `{name, command, paths}`: the flow verifier then runs a command only when a changed file is
  under its paths. The pre-push hook runs the build's command in either form, `init` names a
  malformed entry among the gaps, and the config's `_readme` says how to scope a command.
- The testing guide template has a place for the command that runs one test or one group alone,
  which the implement and test steps use instead of the whole test command.
