---
name: comments
description: Address the review comments on an item's PR. Lists the unresolved threads, grades each (valid, nit, wrong), spawns the comment-addresser in the task worktree per thread, re-requests review, grades a quiz answer and marks the draft ready on a pass, and stops when the PR is merged or closed or nothing is new. Use when the user asks to address comments on a PR, or from the scheduled comments job.
disable-model-invocation: true
---

Address comments on one PR. Plugin root `$P`: the directory holding this skill
(`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path `codex plugin list` prints for `flow`).
GitHub only (`"$P/scripts/comments.sh"`).

1. **Resolve the PR**: from the argument, or the item's state `pr`. `comments.sh state <pr>`:
   merged or closed → release is the steward's job; report and stop.
2. **Threads**: `comments.sh threads <pr>` lists the unresolved review threads. None, and no new
   plain comment since the last pass (`comments.sh issue-comments`, compare with
   `<reports>/comments.json`) → stop, "quiet".
3. **Grade each thread** yourself, reading the code at the line as it is now:
   - `valid`: a real defect, a broken rule, a spec miss, or a better design at equal cost.
   - `nit`: style or wording with no behaviour change.
   - `wrong`: the comment misreads the code, the rule or the spec; or it asks for scope creep.
   Write the grades with one line of reason to `<reports>/comments.json`.
4. **Spawn `comment-addresser`** once per thread, in order of file, in the claimed worktree
   (`"$P/scripts/steward.sh" find <item>`, claim when released). One at a time: each commits
   or replies, resolves when done, pushes. A `gate` result means the owner decides; collect it.
5. **Quiz**: when the PR is a draft and a comment carries `<!-- flow:quiz -->`, look for the
   owner's answer comment after it. Grade against the answer key in `<reports>/quiz.md`: every
   question right → `comments.sh ready <pr>` and reply "quiz passed"; otherwise reply with the
   questions to retry, nothing else.
6. **Re-request review** when at least one thread changed code: one comment per reviewer,
   as the pr-creator did.
7. Report once: threads addressed (valid, nit, wrong counts), commits, the owner's decisions
   pending, the quiz state.

Never batch threads into one commit. Never resolve a thread without a reply. Never mark the
PR ready without a passed quiz when one exists.
