---
name: init
description: Bootstrap a repo for the workstream flow — verify gh auth + a GitHub remote, create the size/epic labels, and stub a ## Glossary section in CLAUDE.md. Run once per repo before first use of grill, to-epic, or to-subissues.
disable-model-invocation: true
---

# workstream: init

One-time, idempotent setup for the workstream flow. Never delete or overwrite existing content — only add what's missing.

## 1. Verify GitHub access

- Run `gh auth status`. If not authenticated, tell the user to run `gh auth login` and stop.
- Run `gh repo view --json nameWithOwner -q .nameWithOwner`. If there is no GitHub remote, tell the user workstream is GitHub-native and stop (offer to help add a remote first).

## 2. Create labels (idempotent)

Check existing labels with `gh label list` first. Before creating a label, check whether an existing label already serves the same purpose under a different name (e.g. an `effort:large` that means the same thing as `size:L`) — don't create a duplicate of the taxonomy under a new name; note the mapping in the summary instead. Then draft the list of genuinely missing labels:

- `epic` — colour `6f42c1` — "Parent issue holding a PRD; tracks sub-issues"
- `size:S` — colour `0e8a16` — "Small slice"
- `size:M` — colour `fbca04` — "Medium slice"
- `size:L` — colour `d93f0b` — "Large slice"
- `size:XL` — colour `b60205` — "Too big — split before shipping"
- `status:in-review` — colour `1d76db` — "PR open — awaiting merge"

## 3. Draft the glossary stub

Read `CLAUDE.md` at the repo root (fall back to `AGENTS.md` if that's the file the repo already uses; prefer `CLAUDE.md`).

- If neither file exists, ask the user which to create — don't pick for them.
- If a `## Glossary` section already exists, leave it untouched and skip this step.
- Otherwise, draft this stub to append:

  ```
  ## Glossary

  <!-- Canonical domain terms — grill maintains this. Format: **Term**: 1-2 sentence definition. _Avoid_: rejected synonyms. No implementation details. -->
  ```

## 4. Preview, then apply

Show the user exactly what's about to change — the labels to be created (and any name-mapping found instead of a duplicate), and the glossary stub to be appended — before touching the repo. On confirmation:

- Create labels with `gh label create "<name>" --color <hex> --description "<desc>"`.
- Append the glossary stub to the target file.

## 5. Locate the code-standards home

The standards channel is the repo's own docs — `init` doesn't author them, it just confirms the skills will find them. Look for a standards source: a conventions section in `CLAUDE.md`/`AGENTS.md`, a `docs/coding-conventions.md`, or a `STANDARDS.md`/`STYLE.md`.

- If one exists, note its path in the summary — `grill`, `ship`, and `two-axis-review` will read it.
- If none exists, tell the user the Standards axis will have nothing to enforce, and offer to stub a `## Code standards` section — but don't create it unasked.

## 6. Summary

Print what was created vs. already present (auth, each label, glossary) and the code-standards source you found (or that none exists). If nothing needed creating, print "workstream already initialised."

Next: run `grill` to stress-test a plan, or `to-epic` directly if the feature is already clear.
