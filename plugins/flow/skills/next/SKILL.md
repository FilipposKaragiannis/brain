---
name: next
description: Run the next step of a tracked item, or of the first ready item when none is named. The orchestrator for one run. Picks the item, reads its state, claims a pool worktree, writes the step brief, runs the step in a fresh subagent, applies the result, and repeats until a human gate, nothing ready, or done. Use when the user says next, run the next item, continue <item>, or work the queue.
disable-model-invocation: true
---

You are the orchestrator for this run. State lives in the tracker; the scripts move it. You
spawn one fresh subagent per step with the written brief and never do a step's work yourself.

Plugin root: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the
path `codex plugin list` prints for `flow`). Call it `$P` below.

## Loop

1. **Prepare the step.**
   ```
   "$P/scripts/next.sh" --json [item]
   ```
   Exit 0 prints JSON: `item, step, agent, skill, worktree, branch, brief, reports, model, effort`.
   Exit 4: the item waits at a gate; tell the user what the gate asks and stop.
   Exit 5: nothing is ready; say so and stop. Exit 6: the item is done; say so and stop.
   Exit 7: a run is already in flight for it; show the run file and stop (another session may be on it).
2. **Run the step in a fresh subagent.** The brief file is the whole task. Spawn the agent
   named in `agent` (Claude: the Agent tool with `subagent_type` = that name; Codex: spawn the
   custom agent of that name) with the prompt "Follow the brief at `<brief>` exactly. Work in
   `<worktree>`." When `agent` is empty, invoke the skill `flow:<skill> <item>` instead (plan,
   implement, review, explain orchestrate their own subagents).
   Never run two steps of one item at once. Wait for the subagent to finish.
3. **Apply the result.**
   ```
   "$P/scripts/advance.sh" <item> --json
   ```
   It reads `<reports>/<step>.json`, which the subagent wrote. Exit 0: the next step is ready,
   go to 1 with the same item. Exit 4: a gate was raised and the owner was notified; report the
   gate text and stop. Exit 6: every step ran; report and stop.
   If the subagent wrote no result, read its final message and pass the facts yourself:
   `--status done|fail|gate --summary "..."` (and `--gate <name> --message "..."` for a gate).
4. **Report** in one short block: item, steps run, where it stopped, what the owner must do.

## Rules

- Never start an item that overlaps a claimed item's `touches`; `next.sh` refuses, do not override.
- Never reset or release a worktree yourself; the steward does that, and never with uncommitted changes.
- A re-size by one step continues; two steps or into L stops at a plan-approval gate. Do not argue with it.
- Unattended runs use `.flow/run-unattended.sh`, which drives this same loop from a shell.
