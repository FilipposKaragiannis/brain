---
name: pr
description: Open or update the pull request for an item with the pr-creator agent: base from the parent or the config, the house PR body with the verify report, a draft while the owner has a quiz to pass in the console, review requests in separate comments, the PR linked on the item. Use when the user asks to open a PR for an item or when the next step of an item is pr.
disable-model-invocation: true
---

Open the PR for one item. Plugin root `$P`: the directory holding this skill
(`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Preconditions**: `<reports>/verify.json` is `pass`; the worktree is clean; every commit is
   on the task branch. Otherwise stop with status `fail` and say which.
   **Open blocker**: an item in the item's `blocked_by` that is still open means no PR yet,
   unless the owner's answer in the brief says to open it now. Stop with status `gate`, gate
   `ambiguity`, never `fail` (a fail runs the step again at once and escalates while the blocker
   is still open). The message's first line, in bold: **<blocker> is still open: wait for it, or
   open the PR now?** Set `"condition": "blocked_by:<blocker>"`, so the health job clears the
   gate once the blocker closes and this step runs again, and one option, `{"label": "Open it
   now", "text": "Open the PR now on <base>; do not wait for <blocker>.", "recommended":
   false}`. Two blockers open: the condition names the one to close first.
2. **Spawn `pr-creator`** with the step brief plus the path of [PR-BODY.md](PR-BODY.md) (the
   house body) and, when they exist, `<reports>/explain.html` and `quiz.md`.
3. **Result** `<reports>/pr.json`: `done` with the URL (under `pr`), the base and why, draft or
   ready, the reviewers asked. A quiz never goes on the PR: the owner takes it in the console,
   which marks the draft ready on a pass. The profile raises the merge gate after this step; the orchestrator
   notifies the owner with the URL and the verify summary.
   A `fail` or a `gate` names, in its summary or message, what the owner runs or does to unblock
   it, filled in for this item: the git or gh command (`git -C <worktree> push -u origin
   <branch>`, `gh pr create --base <base> --head <branch>`) or the tracker action (merge the
   blocker's PR, close gh#40). The escalation gate a last failed attempt raises quotes that
   summary, so the owner never reads only "do it by hand".
4. Report once: the URL, the base, draft or ready, and the warning when the base is not the
   default branch (the merge will not auto-close the item; closeout does).

Never open a PR on a failing verify. Never pick the default branch as base when the item has a
parent with a branch. Never tag reviewers in the body; one comment per reviewer.
