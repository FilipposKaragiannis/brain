---
name: pr
description: Open or update the pull request for an item with the pr-creator agent: base from the parent or the config, the house PR body with the verify report, draft plus quiz when the explain step ran, review requests in separate comments, the PR linked on the item. Use when the user asks to open a PR for an item or when the next step of an item is pr.
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
3. **Result** `<reports>/pr.json`: `done` with the URL, the base and why, draft or ready, the
   reviewers asked. The profile raises the merge gate after this step; the orchestrator
   notifies the owner with the URL and the verify summary.
4. Report once: the URL, the base, draft or ready, and the warning when the base is not the
   default branch (the merge will not auto-close the item; closeout does).

Never open a PR on a failing verify. Never pick the default branch as base when the item has a
parent with a branch. Never tag reviewers in the body; one comment per reviewer.
