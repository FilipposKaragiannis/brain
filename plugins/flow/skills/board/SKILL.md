---
name: board
description: Show the flow board. Every adapter, every claim. The worktree pool with item, step and last event, every open item with its state and blockers, the gates waiting on the owner, and overlapping claims. Use when the user asks what is running, what is ready, what is blocked, or wants the dependency graph of an epic or the priorities graph of the board.
disable-model-invocation: true
---

Read-only. Never changes state.

Plugin root: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the
path `codex plugin list` prints for `flow`). Call it `$P`.

1. Run `"$P/scripts/board.sh"` and show its Markdown as is. Add `--json` when the user wants the
   raw model.
2. Two graphs, for every adapter (GitHub, local, any other), built from the items each lists:
   - Dependencies of one epic: `"$P/scripts/board.sh" --graph <epic-id> --mermaid`, for example
     `gh#12` or `local:epic/3`. One column per wave, an edge per blocker, the critical path in
     a thick red stroke, each item filled by its priority.
   - Priorities of the whole board: `"$P/scripts/board.sh" --graph priorities --mermaid`. Every
     open item but epics, one column per priority (highest first), an edge per blocker. A dashed
     red `inversion` edge is a lower priority item blocking a higher one: say each in one line.
   Show the output as is in a fenced `mermaid` block. The script draws it; never redraw or
   recompute it. Without `--mermaid` it prints the JSON model.
3. A `## Health` section appears when something is stale: a run record with no live process
   (the pool row says `dead run`, not `running on <host>`) or a gate waiting past the reminder.
   Say what it means in one line and that the `health` job clears and resumes it, or run
   `"$P/scripts/steward.sh" health --dry-run`.
4. When a gate waits, say in one line per gate what the owner must do, and how to clear it:
   `"$P/scripts/gate.sh" clear <item> "<answer>"`.
