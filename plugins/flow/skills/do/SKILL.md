---
name: do
description: The front door to the flow. Takes a plain sentence about the backlog, the agents, the worktrees or the gates and does the matching thing: show what is running, ready, blocked or waiting, file a bug, task or epic, start or continue an item, approve a plan, address PR comments, free a worktree. Use when the user talks about work items, tasks, bugs, epics, the board, gates or what the agents are doing, in their own words and without naming a skill.
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
   | free, claim or add a worktree; a conflict in one | `steward` |
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
5. **For a gate, use the user's words as the answer.** Never write one for them; no answer in
   the sentence means ask for it.
6. **Report** what the skill reported, in its words. Add the next thing the user can say.

## Never

- Never start a run on an item you have not named back to the user in this turn.
- Never clear `merge`; the user merges on the host and then answers.
- Never guess between two items.
