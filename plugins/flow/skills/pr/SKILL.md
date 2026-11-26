---
name: pr
description: Open or update the pull request for an item with the pr-creator agent: base from the item's base recorded at claim in claim.json when the item's state.base is set (the parent rule when it is empty, for claims made before the base was recorded), the house PR body with the verify report, a draft while the owner has a quiz to pass in the console, review requests in separate comments, the PR linked on the item. Use when the user asks to open a PR for an item or when the next step of an item is pr.
disable-model-invocation: true
---

Open the PR for one item. Plugin root `$P`: the directory holding this skill
(`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Preconditions**: `<reports>/verify.json` is `pass`; every commit is on the task branch; and
   `"$P/scripts/pr-ready.sh" <item>`, run in the worktree, exits 0. It refuses, printing why, when
   the report's commit is not the worktree's HEAD or the worktree has changes outside `.flow/`.
   Otherwise stop with status `fail`, quoting what it printed: the owner runs verify again.
   **Open blocker**: an item in the item's `blocked_by` that is still open means no PR yet,
   unless the owner's answer in the brief says to open it now. Stop with status `gate`, gate
   `ambiguity`, never `fail` (a fail runs the step again at once and escalates while the blocker
   is still open). The message's first line, in bold: **<blocker> is still open: wait for it, or
   open the PR now?** Set `"condition": "blocked_by:<blocker>"`, so the health job clears the
   gate once the blocker closes and this step runs again, and one option, `{"label": "Open it
   now", "text": "Open the PR now on <base>; do not wait for <blocker>.", "recommended":
   false}`. Two blockers open: the condition names the one to close first. Picking that option
   (`gate.sh clear <item> --option 1`) waives the blocker for this item, so `next.sh` runs this
   step again while it is still open and the brief carries the answer; an answer in words waives
   nothing, and the item waits for the blocker to close.
2. **Spawn `pr-creator`** with the step brief plus the path of [PR-BODY.md](PR-BODY.md) (the
   house body) and, when they exist, `<reports>/explain.html` and `quiz.md`. The PR is a GitHub
   PR on the origin, opened with `gh pr create`, whatever tracker holds the item: a local item
   gets one too, and the tracker only records it. A pushed branch is no PR.
3. **Result** `<reports>/pr.json`: `done` with the URL (under `pr`), the base and why ("base
   <b>, recorded at claim", or the parent rule for a claim with no `state.base`), draft or
   ready, the reviewers asked. A quiz never goes on the PR: the owner takes it in the console,
   which marks the draft ready on a pass. The profile raises the merge gate after this step;
   the orchestrator notifies the owner with the URL and the verify summary.
   **No PR**: only when the branch has nothing to merge (a clean tree and no diff against the
   base, `git diff --quiet <base>...HEAD`), the result is `done` with no `pr` key and a summary
   that says why the item needs no PR. `advance.sh` then closes the item with that summary and
   releases the worktree, and raises no merge gate. A branch with changes is never `done` without
   a PR: `advance.sh` finds a PR on the task branch and records it, and with none raises an
   escalation gate.
   A `fail` or a `gate` names, in its summary or message, what the owner runs or does to unblock
   it, filled in for this item: the git or gh command (`git -C <worktree> push -u origin
   <branch>`, `gh pr create --base <base> --head <branch>`) or the tracker action (merge the
   blocker's PR, close gh#40). The escalation gate a last failed attempt raises quotes that
   summary, so the owner never reads only "do it by hand".
4. End with one report: the URL, the base and where it came from (recorded at claim or the parent
   rule), draft or ready, and the warning when the base is not the default branch (the merge
   will not auto-close the item; closeout does).

Never open a PR on a failing verify. With the item's `state.base` set, never pick a base other
than the item's recorded base, `base` in the worktree's `.flow/claim.json`. `state.base` on the
tracker is a copy anyone who can edit the item can change: when it differs from the claim's, or
the claim has none, stop with status `fail` naming both. Never pass a base to `git` or `gh` that
starts with `-`, has a character outside `^[A-Za-z0-9._/-]+$` or fails
`git check-ref-format --branch`; stop with status `fail` instead. With `state.base` empty (a
claim made before the base was recorded, whose `claim.json` holds only the config base), take
the parent rule and never the default branch when the item has a parent with a branch. Never
tag reviewers in the body; one comment per reviewer.
