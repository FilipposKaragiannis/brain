---
name: board
description: Show the flow board. Every adapter, every claim. The worktree pool with item, step and last event, every open item with its state and blockers, the gates waiting on the owner, and overlapping claims. Use when the user asks what is running, what is ready, what is blocked, or wants the dependency graph of an epic.
disable-model-invocation: true
---

Read-only. Never changes state.

Plugin root: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the
path `codex plugin list` prints for `flow`). Call it `$P`.

1. Run `"$P/scripts/board.sh"` and show its Markdown as is. Add `--json` when the user wants the
   raw model.
2. For a GitHub epic, `"$P/scripts/board.sh" --graph gh#<n>` prints the dependency model
   (waves, nodes, critical path). Render it as a Mermaid flowchart: one subgraph per wave, an
   edge per blocker, the critical path with a thicker stroke. Keep the renderer dumb: it formats
   the model and never recomputes waves.
3. When a gate waits, say in one line per gate what the owner must do, and how to clear it:
   `"$P/scripts/gate.sh" clear <item> "<answer>"`.
