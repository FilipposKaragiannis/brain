---
name: help
description: Show what the flow can do, like a man page. Lists every flow skill with what it does, how to call it on Claude and on Codex and whether it runs by itself; `help <skill>` shows one in detail; `help lines` shows the steps each kind and size of item runs and where it stops. Use when the user asks what is available, how to do something with the flow, or what a skill or a gate means.
disable-model-invocation: true
---

Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex
the path `codex plugin list` prints for `flow`).

Run `"$P/scripts/help.sh" [<skill> | lines | gates]` and show its output as is. It reads the
skills and `profiles.json` of the installed plugin, so it is always current. No argument: the
list. `help jobs` covers the scheduled jobs, including `health`, which checks the worktree pool and
the gates. When the user asks something the output answers, point at the line; do not paraphrase
the whole page. For every plugin at once, `meta:map` draws the page.
