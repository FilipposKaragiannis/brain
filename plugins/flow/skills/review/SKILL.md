---
name: review
description: Review an item's diff at its profile depth with the standards review engine (two axes, extra reviewers by path, refutation pass) and turn the verdict into the step result: a surviving P0 or an unmet acceptance line sends the item back to implement. Use when the user asks to review an item or when the next step of an item is review. For a plain branch or PR review without an item, use standards:review directly.
disable-model-invocation: true
---

Review one item's diff. Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}`
on Claude; on Codex the path `codex plugin list` prints for `flow`).

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

1. **Fixed point**: the item's base. The parent's task branch when the item has a parent with a
   claimed branch, else `base` from `.flow/config.yaml`. Say it.
2. **Depth** from the profile (`next.sh` prints it; else `review_depth` in `$P/profiles.json`):
   - `quick`: standards and spec axes, the test reviewer when tests changed; refute P0 and
     every Spec P1.
   - `standard`: every axis the diff touches; refute P0 and P1.
   - `deep`: every axis; refute every finding, including P2.
3. **Invoke the engine**: the Skill tool with `standards:review`, telling it the fixed point,
   the spec (the item id or its body), and the depth. On Codex: `$review` from the standards
   plugin. Wait for its report.
4. **Result** to `<reports>/review.md` (the engine's report as is) and `<reports>/review.json`:
   - any surviving P0 → `{"status": "fail", "summary": "<count> P0: <first finding>"}`; the fix
     loop sends the item back to implement with this summary. Record each surviving P0 as a
     lesson: `"$P/scripts/lesson.sh" review-blocker <item> "<finding>" --rule <id> --step review`.
   - a surviving Spec P1 (a requirement or an acceptance line the diff must carry, met in part
     or not at all) → `{"status": "fail", "summary": "<count> unmet acceptance: <first
     finding>"}`; the fix loop sends the item back to implement. A note in the PR body does not
     meet a line. A line a later step proves (the verify step's checks, the owner's feel test)
     is pending, not unmet: the review runs before both and never fails on it. Only the owner
     drops a line, in the item: one struck through or moved to `## Out of scope` is no longer a
     requirement.
   - other P1s or P2 only → `{"status": "done", "summary": "<verdict per axis>"}`; the P1s go
     into the PR body's review section, the P2s are comments.
   - the engine could not run (no diff, no standards block) → `fail` with the reason.
5. End with one report: the verdict per axis and where the report is.

Never grade findings yourself; the engine and its refutation pass do. Never review code the
diff does not touch.
