---
name: arsenal
description: Refresh and republish the skills-arsenal artifact — a searchable index of every skill across standalone install and both plugins (workstream, spec-driven-development), showing what each does and whether it auto-invokes or waits to be asked. Use when the user asks to see, refresh, or update the skills arsenal, toolkit map, or skills dashboard.
disable-model-invocation: true
---

# arsenal

The data in `.scratch/skills-arsenal.html` is generated, not hand-authored — the
`SKILLS` array between the `AUTO-GENERATED:SKILLS` markers is derived straight from
every `SKILL.md`'s frontmatter. Never hand-edit that block.

1. From the `brain` repo root, run:
   ```
   node AI/generate-arsenal.js
   ```
   It parses `AI/skills/*/SKILL.md` and `plugins/*/skills/*/SKILL.md`, and reports
   how many skills it found and how many are auto- vs manual-invoked.
2. Publish `.scratch/skills-arsenal.html` with the Artifact tool. Redeploy to the
   existing URL rather than minting a new one:
   `https://claude.ai/code/artifact/c8c66556-45b5-4d99-8d3e-0ea676095a50`
   - If publishing in the same session that already published this file, the
     `url` param isn't required — same `file_path` redeploys automatically.
   - If that URL 404s or the user says it's stale, ask them for the current one
     and update it here.
3. Tell the user what changed (skill count delta, any new/removed skills) —
   not just "done."

A git post-commit hook (`.git/hooks/post-commit`) already runs step 1 automatically
whenever a commit touches a `SKILL.md` under `AI/skills` or `plugins/*/skills`, so
the file on disk is usually already current — this skill exists for the "publish it
now" step, and as a manual fallback if the hook didn't fire (e.g. hooks aren't
copied on `git clone`, so a fresh checkout of this repo needs the hook reinstalled).
