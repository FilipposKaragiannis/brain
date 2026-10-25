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
   `gate.sh list --json` prints the same gates as one array, oldest first, each with its claimed
   worktree (or null), its age in seconds and its numbered questions with their recommended
   answers, parsed as in "Asking" below (empty when the message is not numbered questions).
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
| `decomposition` | the task list, sizes and blockers; on a task whose children exist, clearing it splits the task: step `split`, its worktree back to the pool (kept when it has uncommitted changes) |
| `plan-approval` | `plan.md`, or sends it back with the change |
| `feel-test` | they launched it and it feels right |
| `merge` | the PR is merged; the next `next` job clears it and frees the worktree (`steward.sh sweep`), or run the sweep now |
| `escalation`, `ambiguity` | the decision, or the fix, in a sentence |

A gate nobody answers is not forgotten: the `health` job reminds once per `jobs.health.gate_reminder`
(24h) while it waits, and the board's `## Health` section lists it.

## Answering on the tracker

On GitHub the owner can answer without a session: a comment on the issue, after the gate's
comment, that starts with `/answer`. The rest is the answer; `/answer` alone takes the
recommendations. The scheduled `next` job reads it, clears the gate with those words and
reacts +1, then picks the item up in the same run. Only the authenticated user's comments
count, or the logins in `github.answer_from`. The merge gate is not answered this way.

## Asking (agents raising `ambiguity`)

The message is numbered questions, one per line, each answerable in a sentence. Under each, a
line `Recommended:` with the answer the agent would pick and why, in one clause, from the code
or the spec. The owner can then reply "as recommended" or change one answer.

```
1. Should the motion touch the ball, or stay visual only?
   Recommended: visual only, so the charge hold stays hash-inert and the goldens do not move.
2. Is the motion the same for the tap and the depth pass?
   Recommended: the same, until a feel test says otherwise.
```

## Never

- Never clear a gate without the owner's answer in this turn.
- Never clear `merge` before the PR is merged or closed. The sweep clears it on the merge itself.
