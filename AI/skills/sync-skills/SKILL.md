---
name: sync-skills
description: Pull the latest commits from tracked upstream skill repos (e.g. mattpocock/skills), review what changed since the last sync, and port improvements into your own refined skills. Use when periodically reviewing an upstream skills repo for updates, or asked to sync/absorb changes from a tracked source.
disable-model-invocation: true
---

# Sync Skills

Your skills under `AI/skills` and `plugins/*/skills` are **refined, not vendored** — you pull
ideas from tracked upstream repos and adapt them to your own workflow, structure, and voice.
This skill reviews what changed upstream since the last pass and ports over what's actually
useful, without overwriting your customizations.

## Tracked sources

`sources.json` in this directory lists every tracked repo:

```json
{ "name": "...", "path": "...", "remote": "...", "branch": "...",
  "lastSyncedCommit": "...", "lastSyncedDate": "..." }
```

To track a new repo, append an entry with `path`/`remote`/`branch` filled in. Leave
`lastSyncedCommit` unset — the first run for a new source has no baseline, so ask the user
whether to review its full history or just set `lastSyncedCommit` to current `HEAD` and start
tracking from today.

## Provenance — don't re-derive the mapping every time

`provenance.json` records, per source, which local skills (across `AI/skills` *and* both
plugins) are adapted from which upstream skill, which local skills are verified originals with
no upstream equivalent (`noEquivalent`), judgment-heavy upstream changes surfaced but not yet
decided on (`pendingDecisions` — check this before re-surfacing the same finding), which were
deliberately dropped and shouldn't be re-suggested (`dropped`), and which whole plugin dirs are
confirmed unrelated to that source (`unrelatedPlugins`). This is the accumulated answer to
"which of my skills came from where" — always consult it before re-matching by
name/description from scratch.

Keep it current as you go:
- A changed upstream skill with a `mapped` entry → you already know the local counterpart, skip
  straight to evaluating the diff.
- A changed upstream skill with no entry anywhere → work out whether it maps to something local,
  is genuinely new, or is upstream-specific, then add the finding to `mapped` or `noEquivalent`
  so the next run doesn't redo this.
- A local skill gets renamed, split, merged, or newly ported → update or add its entry in the
  same commit that makes the change.

## Process

1. **Fetch.** For each source, `git -C <path> fetch origin` then `git -C <path> log
   <lastSyncedCommit>..origin/<branch> --oneline`. If there's nothing new, say so and stop for
   that source.
2. **Gather context.** Read the source's `CHANGELOG.md` (or PR/commit messages if there isn't
   one) for the commits in range — it usually explains the *why* behind a change better than the
   diff alone. Then look at which skill directories actually changed:
   `git -C <path> diff --name-only <lastSyncedCommit>..origin/<branch> -- skills/`.
3. **Match to your own skills via `provenance.json`** (see above) rather than re-deriving the
   mapping by name/description each run. Only reason from scratch about skills `provenance.json`
   doesn't yet cover, then record what you find.
4. **Evaluate, don't diff-apply.** For each candidate, decide whether it's worth porting given
   how far your version has already diverged. Skip anything that's upstream-specific (their repo
   conventions, their plugin wiring) or that conflicts with a deliberate change you already made.
   Net-new upstream skills are candidates for adoption, not just skills with local matches.
5. **Present findings** as a short routed list — skill, one-line change, port/skip/adapt and
   why — the way `retro` routes findings. Apply the clear wins directly; for genuinely
   judgment-heavy ones, don't guess — surface them to the user, and record any not resolved this
   run in `provenance.json`'s `pendingDecisions` so they're not re-derived from scratch next time.
6. **Port by adapting**, not copying: rewrite the idea in the local skill's existing voice and
   structure, the way past syncs did (see `git log --grep="Sync.*mattpocock"` in this repo for
   examples of the target shape).
7. **Update state.** Set `lastSyncedCommit` (to the `origin/<branch>` SHA you just reviewed) and
   `lastSyncedDate` for that source in `sources.json`. Make sure every `mapped`/`noEquivalent`
   finding from step 3 landed in `provenance.json`.
8. **Refresh the arsenal.** If any `SKILL.md` changed, the post-commit hook regenerates
   `.scratch/skills-arsenal.html` automatically on commit. Run the `arsenal` skill afterward to
   publish the refreshed artifact to its live URL.
9. **Offer to commit.** Don't commit automatically — summarize what was ported (skill by skill,
   like commit `7acb8ca`'s message) and ask before creating the commit.
