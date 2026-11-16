bump: patch

- The app's tests (`npm test`, and so `npm run check` and the `console-app` commit gate) and the
  plugin's shell suite run in the repository's test sandbox: no git repository variable, a
  throwaway home and git config, and a run that changes the checkout it runs from fails. With
  `GIT_DIR` exported, as in a git hook, the sync tests wrote their `t` identity into the
  repository being committed.
