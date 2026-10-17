---
name: do
description: The front door to the flow. Takes a plain sentence about the backlog, the agents, the worktrees or the gates and does the matching thing: show what is running, ready, blocked or waiting, file a bug, task or epic, start or continue an item, approve a plan, address PR comments, free a worktree, start an unattended run once or on a schedule. Use when the user talks about work items, tasks, bugs, epics, the board, gates or what the agents are doing, in their own words and without naming a skill.
---

Route one sentence to the flow skill that does it. You translate; the skills act. Plugin root
`$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path
`codex plugin list` prints for `flow`).

## Steps

1. **Read the sentence for its intent**, in whatever words the user used. Pick the row:

   | The user means | Skill |
   |---|---|
   | what is going on, running, stuck, ready, blocked, waiting on me; a dependency graph | `board` |
   | file, add, log, raise a bug, task or epic | `new` |
   | work on, start, continue, pick up, run, "the next one", "the bots bug" | `next` |
   | plan, grill, design, break down an item | `plan` |
   | write tests, review, verify, open the PR for an item | `test`, `review`, `verify`, `pr` |
   | approve, confirm, sign off, answer a waiting gate; "what is waiting on me" | `gate` |
   | reviewers commented, address the comments | `comments` |
   | file my notes, triage the notes file, turn a backlog file into issues | `intake` |
   | free, claim or add a worktree; a conflict in one | `steward` |
   | run unattended, on its own, in the background, "a one-off unattended run", "N in parallel" | **Unattended**, below |
   | a repeating or scheduled unattended run, "keep working the backlog", "every 30 minutes" | **Unattended**, below |
   | set up or check the flow in this repo | `init` |
   | what can I do, how do I, what does X do | `help` |

   Two intents in one sentence ("file this and start it"): do them in order, one confirmation.
2. **Resolve the item** when the sentence names one by words ("the bots bug"). Run
   `"$P/scripts/board.sh" --json`, match on the title, and use the id. Several close matches:
   list the top three with their ids and ask which. None: say so and offer `new`.
3. **Ask once before anything that spends money or changes state**: `next` (it runs agents),
   `plan`, `test`, `review`, `verify`, `pr`, `gate` (it clears a gate), `steward` release.
   One line: the item, what will run, where it stops. For `next`: "Run gh#340 (bug) through
   reproduce, implement, test, review, verify and pr? It stops at the merge gate." Reading
   (`board`, `help`) and `new` need no question. A sentence that already says go ("start it
   now") counts as the answer when the item is unambiguous.
4. **Run the skill.** Read `"$P/skills/<skill>/SKILL.md"` and follow it as written, with the
   resolved item as its argument. User-only skills cannot be called by a model on every host;
   reading the file does the same job, so do that for all of them.
5. **Unattended.** No skill: the shell runs it, so it keeps going after this session. Resolve the
   numbers from the sentence: one item or the queue, the workers (default 1), `--max-steps`
   (default 15; the most agent steps one run may start, a cost cap). Ask once, in one line: "Run
   the queue unattended, 2 workers, up to 15 steps each? Each stops at its first gate, M tasks
   pass plan-approval only if auto_gates lists M." The host is the one you run on.
   - **One-off:** start it in the background, from the repository root, its output in the log:
     `.flow/jobs/next.sh <host> [item] --max-steps N [--workers N] &` (the job adds the lock,
     the log under `.flow/log/` and the quiet exits). On Claude use the Bash tool's background
     mode. Say where the log is and that `board` shows progress.
   - **Repeating:** ask the cadence (default every 30 minutes). Where this host gives you a tool
     that creates a scheduled task on this machine, create one whose prompt runs that command,
     on the owner's yes. Otherwise give the exact command and cadence for their scheduler
     (launchd, cron) in one block. Never claim a schedule exists unless the tool confirmed it.
   - Parallel is `--workers N`, capped by the pool (`pool_max`). Say so when N is above it.
6. **For a gate, use the user's words as the answer.** Never write one for them; no answer in
   the sentence means ask for it.
7. **Report** what the skill reported, in its words. Add the next thing the user can say.

## Never

- Never start a run on an item you have not named back to the user in this turn. An unattended
  run on the queue names the queue: "the first ready items, N at a time".
- Never clear `merge`; the user merges on the host and then answers.
- Never guess between two items.
