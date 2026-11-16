bump: patch

- The meta suite runs in the repository's test sandbox: no git repository variable, a throwaway
  home and git config, and a run that changes the checkout it runs from fails.
