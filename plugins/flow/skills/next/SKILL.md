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
   "$P/scripts/next.sh" --json [item | --pick <name>]
   ```
   `--pick <name>` takes the first ready item the filter `pick.<name>` in `.flow/config.yaml`
   keeps (assignee, status, labels, kinds, trackers, or one tracker's query; the mapping is in
   `adapters/README.md`, Pick filters), when the user asks for their own items or a named filter.
   Exit 2 names the filters there are, or what the filter has wrong; say so and stop.
   Exit 0 prints JSON: `item, step, agent, skill, worktree, branch, brief, reports, model, effort`.
   Exit 3: no free worktree, and every ready item left needs a new one; give the reason its
   last stderr line names (the unclaimed items waiting, what the claimed ones are doing), say
   which worktrees hold what (`steward.sh pool`) and stop.
   Exit 4: the item waits at a gate, or is held behind another open item (the line names the
   holder and why, or the open blockers and `(blocked by)`); tell the user what the gate asks,
   or what it waits behind, and stop.
   Exit 5: nothing is ready; give the reason the last stderr line names and stop. Exit 6: the
   item is done; say so and stop.
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

- Never start an item held behind another (`state.held_by`) past its plan while that one is open; `next.sh` refuses, do not override. Its plan, sent back at the gate, still runs and decides the hold anew.
- Never start an item, claimed or not, at any step while one of its native blockers (`blocked_by`) is open; `next.sh` refuses, do not override. Once the last one closes, its step runs again and its brief says to merge the base first.
- Never reset or release a worktree yourself; the steward does that, and never with uncommitted changes.
- A re-size by one step continues; two steps or into L stops at a plan-approval gate. Do not argue with it.
- Unattended runs use `.flow/run-unattended.sh`, which drives this same loop from a shell.
