bump: patch

- The Agents page lists the current Codex models (`gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-astra`,
  `gpt-6-luna`), and the deprecated `jobs.model` fallback maps opus to `gpt-6.1-sol` and sonnet to
  `gpt-6.1-terra`, as flow does.
- A host flow stopped on a model it does not know shows as "stopped on an unknown model".
