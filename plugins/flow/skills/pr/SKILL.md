---
name: pr
description: Open or update the pull request for an item with the pr-creator agent: base from the item's base recorded at claim in claim.json (the parent rule for claims made before the base was recorded), the house PR body with the verify report, a draft while the owner has a quiz to pass in the console, review requests in separate comments, the PR linked on the item. Use when the user asks to open a PR for an item or when the next step of an item is pr.
disable-model-invocation: true
---

Open the PR for one item. Plugin root `$P`: the directory holding this skill
(`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Preconditions**: `<reports>/verify.json` is `pass`; the worktree is clean; every commit is
   on the task branch. Otherwise stop with status `fail` and say which.
2. **Spawn `pr-creator`** with the step brief plus the path of [PR-BODY.md](PR-BODY.md) (the
   house body) and, when they exist, `<reports>/explain.html` and `quiz.md`.
3. **Result** `<reports>/pr.json`: `done` with the URL (under `pr`), the base and why ("base
   <b>, recorded at claim"), draft or ready, the reviewers asked. A quiz never goes on the PR:
   the owner takes it in the console, which marks the draft ready on a pass. The profile raises
   the merge gate after this step; the orchestrator notifies the owner with the URL and the
   verify summary.
4. Report once: the URL, the base and that it was recorded at claim, draft or ready, and the
   warning when the base is not the default branch (the merge will not auto-close the item;
   closeout does).

Never open a PR on a failing verify. Never pick a base other than the item's recorded base, `base`
in the worktree's `.flow/claim.json`. `state.base` on the tracker is a copy anyone who can edit
the item can change: when it is set and differs from the claim's, or the claim has none, stop with
status `fail` naming both. Never pass a base to `git` or `gh` that starts with `-`, has a character
outside `^[A-Za-z0-9._/-]+$` or fails `git check-ref-format --branch`; stop with status `fail`
instead. With none recorded (claims made before the base was recorded), never the default branch
when the item has a parent with a branch. Never tag reviewers in the body; one comment per reviewer.
