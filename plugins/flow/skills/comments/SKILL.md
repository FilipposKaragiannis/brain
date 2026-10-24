---
name: comments
description: Address the review comments on an item's PR and keep it mergeable. Merges the base in when the PR conflicts with it, lists the unresolved threads, grades each (valid, nit, wrong), spawns the comment-addresser in the task worktree per thread, re-requests review, grades a quiz answer and marks the draft ready on a pass, and stops when the PR is merged or closed or nothing is new. Use when the user asks to address comments on a PR, or from the scheduled comments job.
disable-model-invocation: true
---

Address comments on one PR. Plugin root `$P`: the directory holding this skill
(`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path `codex plugin list` prints for `flow`).
GitHub only (`"$P/scripts/comments.sh"`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Resolve the PR**: from the argument, or the item's state `pr`. `comments.sh state <pr>`:
   merged or closed → release is the steward's job; report and stop.
   The item is the one the PR's branch names (`flow/gh-310` is `gh#310`).
2. **Conflicts**: `state` says `mergeable: CONFLICTING` → in the claimed worktree
   (`"$P/scripts/steward.sh" find <item>`, claim when released), with a clean tree, spawn the
   `implementer` with this brief: `git fetch origin`, `git merge "origin/<baseRefName>"` into the
   task branch (never rebase, never force), resolve each conflict so both sides keep their intent,
   build and run the tests the conflicted files touch, commit the merge as `chore: merge <base>
   into <branch>`. Then spawn the `verifier`; on `pass` run `git push origin "HEAD:<headRefName>"`
   (never `-f` or `--force-with-lease`: a merge always fast-forwards) and re-request review (step
   7) naming the merge commit. A conflict whose resolution needs the owner (two intents that
   cannot both hold) → `"$P/scripts/gate.sh" raise <item> ambiguity` with each file and the
   choice; abort the merge and stop. A dirty tree or a failing verify → abort or leave the merge
   unpushed, report it, stop. `UNKNOWN` means GitHub is still computing: skip, the next pass sees
   it.
3. **Threads**: `comments.sh threads <pr>` lists the unresolved review threads. None, no new
   plain comment since the last pass (`comments.sh issue-comments`, compare with
   `<reports>/comments.json`) and no merge in step 2 → stop, "quiet".
4. **Grade each thread** yourself, reading the code at the line as it is now:
   - `valid`: a real defect, a broken rule, a spec miss, or a better design at equal cost.
   - `nit`: style or wording with no behaviour change.
   - `wrong`: the comment misreads the code, the rule or the spec; or it asks for scope creep.
   Write the grades with one line of reason to `<reports>/comments.json`.
5. **Spawn `comment-addresser`** once per thread, in order of file, in the claimed worktree
   (`"$P/scripts/steward.sh" find <item>`, claim when released). One at a time: each commits
   or replies, resolves when done, pushes. A `gate` result means the owner decides; collect it.
6. **Quiz**: when the PR is a draft and a comment carries `<!-- flow:quiz -->`, look for the
   owner's answer comment after it. Grade against the answer key in `<reports>/quiz.md`: every
   question right → `comments.sh ready <pr>` and reply "quiz passed"; otherwise reply with the
   questions to retry, nothing else.
7. **Re-request review** when at least one thread changed code or step 2 merged the base:
   `"$P/scripts/comments.sh" request-review <pr> "<ask>"`, the ask naming the new commits and
   what changed. It asks each reviewer in `reviews.reviewers`, one comment each. Never tag a
   reviewer by hand. A reviewer that stays silent is chased by the comments job, not here.
8. Report once: the conflict merge, threads addressed (valid, nit, wrong counts), commits, the owner's decisions
   pending, the quiz state.

Never batch threads into one commit. Never resolve a thread without a reply. Never mark the
PR ready without a passed quiz when one exists.
