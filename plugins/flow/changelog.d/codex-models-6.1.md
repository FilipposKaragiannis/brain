bump: minor

- The Codex model map follows the current Codex catalog (`codex debug models`, Codex CLI
  0.166.0): opus runs as `gpt-6.1-sol`, the current workhorse, and sonnet as `gpt-6.1-terra`, the
  balanced tier below it; fable stays `gpt-6-astra` and haiku `gpt-6-luna`. `gpt-6-sol` is the
  previous generation. `host_codex_model`, the roster's Codex agents and the init example change
  with it. A `jobs.codex.model` set by hand is passed on as is, as before.
