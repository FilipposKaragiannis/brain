---
name: gate
description: Show the gates waiting on the owner, or answer one so the item can continue. A gate is where a run stops and asks: interview, decomposition, plan-approval, feel-test, merge, escalation, ambiguity. Use when the user wants to approve a plan, confirm a spec or a task list, answer a gate, or see which gates are waiting.
disable-model-invocation: true
---

Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex
the path `codex plugin list` prints for `flow`). The script is `"$P/scripts/gate.sh"`.

## Steps

1. **No argument: list.** `gate.sh list` prints time, item, gate and the first line of what it
   asks. One line per gate: what the owner must decide. Nothing waiting: say so.
2. **`<item> <answer>`: clear.** Read the gate's message first (the item's last gate comment, or
   `/flow:board`), so the answer fits the question. Then:
   ```
   "$P/scripts/gate.sh" clear <item> "<answer>"
   ```
   The answer is the owner's words, recorded on the item. Do not write one for them.
3. **Say what happens next**: `next <item>` continues from the step after the gate.

## Which answer each gate wants

| gate | the owner confirms |
|---|---|
| `interview` | the recap of the spec is right, or says what to change |
| `decomposition` | the task list, sizes and blockers, before the sub-items are created |
| `plan-approval` | `plan.md`, or sends it back with the change |
| `feel-test` | they launched it and it feels right |
| `merge` | the PR is merged (release the worktree with `steward`) |
| `escalation`, `ambiguity` | the decision, or the fix, in a sentence |

## Never

- Never clear a gate without the owner's answer in this turn.
- Never clear `merge` before the PR is merged or closed.
