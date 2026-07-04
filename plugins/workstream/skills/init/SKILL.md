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

Check existing labels with `gh label list` first, then create only the missing ones:

- `epic` — colour `6f42c1` — "Parent issue holding a PRD; tracks sub-issues"
- `size:S` — colour `0e8a16` — "Small slice"
- `size:M` — colour `fbca04` — "Medium slice"
- `size:L` — colour `d93f0b` — "Large slice"
- `size:XL` — colour `b60205` — "Too big — split before shipping"
- `status:in-review` — colour `1d76db` — "PR open — awaiting merge"

Create with `gh label create "<name>" --color <hex> --description "<desc>"`. Skip any that already exist.

## 3. Stub the glossary

Read `CLAUDE.md` at the repo root (fall back to `AGENTS.md` if that's the file the repo already uses; prefer `CLAUDE.md`).

- If neither file exists, ask the user which to create — don't pick for them.
- If the file exists but has no `## Glossary` section, append this stub:

  ```
  ## Glossary

  <!-- Canonical domain terms — grill maintains this. Format: **Term**: 1-2 sentence definition. _Avoid_: rejected synonyms. No implementation details. -->
  ```

- If a `## Glossary` section already exists, leave it untouched.

## 4. Locate the code-standards home

The standards channel is the repo's own docs — `init` doesn't author them, it just confirms the skills will find them. Look for a standards source: a conventions section in `CLAUDE.md`/`AGENTS.md`, a `docs/coding-conventions.md`, or a `STANDARDS.md`/`STYLE.md`.

- If one exists, note its path in the summary — `grill`, `ship`, and `review` will read it.
- If none exists, tell the user the Standards axis will have nothing to enforce, and offer to stub a `## Code standards` section — but don't create it unasked.

## 5. Summary

Print what was created vs. already present (auth, each label, glossary) and the code-standards source you found (or that none exists). If nothing needed creating, print "workstream already initialised."

Next: run `grill` to stress-test a plan, or `to-epic` directly if the feature is already clear.
