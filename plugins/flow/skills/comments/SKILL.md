---
name: comments
description: Address the review comments on an item's PR and keep it mergeable. Merges the base in when the PR conflicts with it, fixes the checks failing on its head, lists the unresolved threads, grades each (valid, nit, wrong), spawns the comment-addresser in the task worktree per thread, re-requests review, marks a draft whose quiz was passed in the console ready, and stops when the PR is merged or closed or nothing is new. Use when the user asks to address comments on a PR, or from the scheduled comments job.
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
   **Answer**: the brief names the owner's answer to the item's last gate ("The owner answered
   the <gate> gate: ..."), or run outside the job, the item's state has `answer_pending:
   comments` with `asked` and `answer`. Carry it out first: it settles what a gate an earlier
   pass raised asked (how a conflict resolves, which fix a check gets). Work on the PR's own
   branch, in the claimed worktree, the way steps 2 and 3 do (`implementer`, `verifier`, push,
   re-request review). An answer that asks for work outside that branch (another branch, the
   PR's base among them; the tracker; another item) is no step's: do none of it, and raise
   `"$P/scripts/gate.sh" raise <item> escalation "<message>" --raised-by "comments job"` with a
   first line in bold, **No step acts on this answer: do it by hand, then clear the gate with no
   answer**, then the answer and what it asks for, then how to do it: each git or gh command in
   full, its PR, branch or item filled in (`gh pr merge 771 --merge`, `gh pr edit 412 --base
   epic/525`), or the tracker action (close gh#40, add gh#41 to the epic). Never only "do it by
   hand". Once the answer is carried out (pushed) or raised again as a gate, and only then, write
   the line the brief names to the file it names: that is how the job knows to take the
   answer, so it is never carried twice. A dirty tree, a failing verify or anything else that
   leaves the answer undone: write nothing and report why; the answer stays pending, and the job
   counts the pass as failed and tries again. Run outside the job, no file is named: once it is
   done, clear the marker yourself, `"$P/adapters/<github|jira|local>/write-state.sh" <item>
   answer_pending=`.
2. **Conflicts**: `state` says `mergeable: CONFLICTING` → in the claimed worktree
   (`"$P/scripts/steward.sh" find <item>`, claim when released), with a clean tree, spawn the
   `implementer` with this brief: `git fetch origin`, `git merge "origin/<baseRefName>"` into the
   task branch (never rebase, never force), resolve each conflict so both sides keep their intent,
   build and run the tests the conflicted files touch, commit the merge as `chore: merge <base>
   into <branch>`. Then spawn the `verifier`; on `pass` run `git push origin "HEAD:<headRefName>"`
   (never `-f` or `--force-with-lease`: a merge always fast-forwards) and re-request review (step
   8) naming the merge commit. A conflict whose resolution needs the owner (two intents that
   cannot both hold) → `"$P/scripts/gate.sh" raise <item> ambiguity "<message>" --condition
   "pr:#<n> conflicting" --raised-by "comments job"` with each file and the choice; abort the
   merge and stop. The health job clears that gate once the PR no longer conflicts. A dirty tree
   or a failing verify → abort or leave the merge unpushed, report it, stop. `UNKNOWN` means
   GitHub is still computing: skip, the next pass sees it.
   **Interrupted work**: when `<reports>/comments-resume.md` exists, the last pass was cut short
   and the claimed worktree may hold its uncommitted work. Read the note, `git status` and
   `git diff` there. That dirty tree is not a reason to stop: give the note and the diff to the
   addresser of the thread the changes belong to (step 6), which continues from them.
3. **Checks**: the brief names failing checks, or `comments.sh failing-checks <pr>` prints any.
   Step 2 pushed a merge → skip: they ran on the old head, the next pass sees the new one's.
   Else in the claimed worktree, with a clean tree, note the head (`git rev-parse HEAD`) and
   spawn the `implementer` with this brief: read the failed logs (`gh pr checks <pr>`, `gh run
   view <run> --log-failed`), find the cause, fix it in the task branch, build and run the tests,
   commit as `fix: make <check> pass`. Then the
   `verifier`; on `pass` run `git push origin "HEAD:<headRefName>"` (never force) and re-request
   review (step 8) naming the fix. A failure that is not the change's (infra, billing, a flake,
   a check red on the base too), or a check still red on the head of an earlier `fix: make
   <check> pass` → no code change: say so in the report and go on to step 4 (a gate only when
   the owner must decide). A dirty tree → no fix: report it, go on to step 4. A failing verify →
   the addressers of step 6 push this branch, so take the attempt off it first: `git switch -c
   "<headRefName>-rejected-<short sha>"` keeps it (commit what it left uncommitted there as `wip:
   rejected fix for <check>`), then `git switch "<task branch>"` and `git reset --hard <noted
   head>`, which drops only the attempt. Never push that branch. Name it in the report and go on
   to step 4.
   A red check never ends the pass: the threads are addressed whatever CI says. A pass that
   leaves a thread for "the next pass" leaves it for good: the comments job gives a thread that
   still waits one more pass, then stops trying it.
4. **Threads**: `comments.sh threads <pr>` lists the unresolved review threads. None, no new
   plain comment since the last pass (`comments.sh issue-comments`, compare with
   `<reports>/comments.json`), no answer carried out, no merge in step 2 and no checks fixed in
   step 3 → stop, "quiet".
5. **Grade each thread** yourself, reading the code at the line as it is now:
   - `valid`: a real defect, a broken rule, a spec miss, or a better design at equal cost.
   - `nit`: style or wording with no behaviour change.
   - `wrong`: the comment misreads the code, the rule or the spec; or it asks for scope creep.
   Write the grades with one line of reason to `<reports>/comments.json`.
6. **Spawn `comment-addresser`** once per thread, in order of file, in the claimed worktree
   (`"$P/scripts/steward.sh" find <item>`, claim when released). One at a time: each commits
   or replies, resolves when done, pushes. A `gate` result means the owner decides; collect it.
   Wait for each addresser in the foreground and never end the turn while one runs: an
   unattended host stops background work after the last turn, and the comments job then counts
   the pass as failed and runs it again.
7. **Quiz**: the owner takes it in the console (`quiz.sh answer`), which grades it, writes
   `<reports>/quiz.json` and marks the draft ready. When the PR is still a draft and that file
   says `passed: true` (the console could not reach GitHub), run `comments.sh ready <pr>`. Never
   grade a comment, and never post the quiz or its answers on the PR.
8. **Re-request review** when at least one thread changed code, step 2 merged the base or step 3
   fixed a check: `"$P/scripts/comments.sh" request-review <pr> "<ask>"`, the ask naming the new
   commits and what changed. It asks each reviewer of the PR's author host, one comment each.
   Never tag a reviewer by hand. A reviewer that stays silent is chased by the comments job, not
   here. `reviews.reviewers` in `.flow/config.yaml` is one list for every PR, or a map: `claude`
   lists the reviewers of a PR Claude wrote, `codex` of one Codex wrote, `default` of a PR whose
   author host is unknown or has no list (unset, codex and claude). The author host is the
   item's `pr_host`, recorded by `link-pr`, else the PR body's footer.
9. Delete `<reports>/comments-resume.md` once every thread of this pass is addressed or replied
   to, and the interrupted work is committed or named in a reply.
10. Report once: the owner's answer carried out or raised again, the conflict merge, the checks
   fixed or left red and why, threads addressed (valid, nit, wrong counts), commits, the owner's
   decisions pending, the quiz state.

Never batch threads into one commit. Never resolve a thread without a reply. Never mark the
PR ready without a passed quiz (`<reports>/quiz.json`) when one exists.
