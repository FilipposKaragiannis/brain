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
   answers, parsed as in "Asking" below (empty when the message is not numbered questions). Then
   `options` (the `{label, text, recommended}` the gate was raised with, `[]` when none),
   `raised_by` (`step <step>`, a job, or `owner`), `answered_by` (who carries the answer out:
   `step <step>`, `comments job, next pass`, `the sweep, once the PR merges`, or `nobody: ...`
   when the owner does it by hand), `condition` (what the gate waits on, or null) and `footer`
   (the line under the message on the tracker: what clears the gate and the command). A gate
   raised by an older flow lists `[]` and nulls for these.
2. **`<item> <answer>`: clear.** Read the gate's message first (the item's last gate comment, or
   `/flow:board`), so the answer fits the question. Then:
   ```
   "$P/scripts/gate.sh" clear <item> "<answer>"
   ```
   The answer is the owner's words, recorded on the item. Do not write one for them.
   **Sent back**: when the owner wants the work redone, not continued:
   ```
   "$P/scripts/gate.sh" clear <item> --back "<what to change>"
   ```
   The step that raised the gate runs again, its brief carrying the owner's note. A note is
   required. Works for `interview`, `decomposition`, `plan-approval` and `feel-test` (which goes
   back to the step that wrote the code).
3. **Say what happens next**, as `gate.sh clear` prints it. The answer waits on what carries it
   out (the item's `answer_pending`, which the board shows in its gate column until a run takes
   it): `next <item>` continues from the step after the gate, or runs the sent-back step again;
   on an item at `done` with an open PR, the comments job's next pass carries the answer out (run
   it now with `jobs/comments.sh <host> <item>`), or raises an escalation gate when the answer
   asks for work outside the PR's branch. An answer no step acts on (the item at `done` with no
   PR or a merged or closed one, or a send-back to `done`) fails, exit 1, and the gate stays:
   tell the owner to do it by hand, then clear the gate with no answer (`gate.sh clear <item>`),
   which carries nothing out.

Each answer also leaves one `answered` line in `<flow home>/events.log`, which the console lists
as "Answered today".

## Which answer each gate wants

| gate | the owner confirms |
|---|---|
| `interview` | the recap of the spec is right, or says what to change |
| `decomposition` | the task list, sizes and blockers. A task whose plan made tracker tasks is already split (step `split`, its worktree back to the pool); to keep it whole, close its children, then clear: the plan step runs again |
| `plan-approval` | `plan.md`, approves it with notes, or sends it back (`--back`) with the change |
| `feel-test` | they launched it and it feels right, or report what is wrong (`--back`) |
| `merge` | the PR is merged; the next `health` or `next` job clears it and frees the worktree (`steward.sh sweep`), or run the sweep now |
| `escalation`, `ambiguity` | the decision, or the fix, in a sentence |

A gate nobody answers is not forgotten: the `health` job reminds once per `jobs.health.gate_reminder`
(24h) while it waits, and the board's `## Health` section lists it.

## Answering on the tracker

On GitHub and Jira the owner can answer without a session: a comment on the issue, after the
gate's comment, that starts with `/answer`. The rest is the answer; `/answer` alone takes the
recommendations. The scheduled `next` job reads it, clears the gate with those words (on GitHub it
reacts +1; on Jira the `Gate cleared` comment is the receipt), then picks the item up in the same
run. Only the authenticated user's comments count (gh's user; the user the Jira API token
belongs to), or the logins in `github.answer_from` and the account ids or emails in
`jira.answer_from`. The merge gate is not answered this way.

## Asking (agents raising a gate)

The message is markdown. Its first line, in bold, is the decision the owner must make; short
bullets of context follow. For `ambiguity`, the rest is numbered questions, one per line, each
answerable in a sentence. Under each, a line `Recommended:` with the answer the agent would pick
and why, in one clause, from the code or the spec. The owner can then reply "as recommended" or change one answer.

```
1. Should the motion touch the ball, or stay visual only?
   Recommended: visual only, so the charge hold stays hash-inert and the goldens do not move.
2. Is the motion the same for the tap and the depth pass?
   Recommended: the same, until a feel test says otherwise.
```

`gate.sh raise <item> <gate> "<message>" [<from step>]` takes three optional flags after those:

- `--options '<json>'`: the choices as data, so the owner can pick one instead of retyping it. A
  JSON array of 1 to 9 `{"label": "<a few words>", "text": "<the answer as the agent will read
  it>", "recommended": true|false}`, at most one recommended. Keep the numbered questions in the
  message too: the options are what a pick sends, the message is what the owner reads.
- `--condition '<condition>'`: what the gate only waits on, when that is something the health job
  can watch: `blocked_by:<item id>` (the blocker closes), `pr:#<n> conflicting` (the PR merges
  cleanly again) or `ci:down` (no check fails; it reads pending checks as not failing, so it may
  clear before they finish, and the next step sees the real state).
- `--raised-by '<who>'`: who asks, when it is not a step (`health job`, `comments job`, `intake
  job`). Left out, it is the step of the run in flight, else the item's step, else `owner`.

A malformed `--options` or `--condition` is dropped with a warning and the gate still raises.
Who carries the answer out is worked out from the item's step, the gate and its PR; the tracker
comment and the notification end with a footer saying it and naming the `gate.sh clear` command,
so an owner on a host without the gate record still knows what to run.

## Never

- Never clear a gate without the owner's answer in this turn.
- Never clear `merge` before the PR is merged or closed. The sweep clears it on the merge itself.
