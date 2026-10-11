---
name: map
description: Show the brain map, one page with every plugin, skill, agent and hook, the flow's steps per profile and where the hooks step into a session, rendered from the sources. Use when the user asks what is available, what a plugin or skill does, when to use one, or wants the map refreshed after a change.
disable-model-invocation: true
---

The map is generated, never written by hand: `tools/generate.sh` renders `docs/map.html` from
`plugins/*/plugin.source.json`, every `SKILL.md` frontmatter, `roster/agents.json`,
`hooks/hooks.json` and `plugins/flow/profiles.json` (`tools/lib/map.py`). `tools/lint.sh` fails
when it is stale, so the committed page always matches the plugins.

## Steps

1. From the marketplace root run `tools/generate.sh`, then `git status --short docs/map.html`.
   A change means the page moved with the sources; say so in one line (what grew or went).
2. **Show it.** On Claude, publish `docs/map.html` with the Artifact tool to the existing page,
   `https://claude.ai/artifact/GuGezptxUrCxVZR5EaEP9v`, so the link stays the same; if that
   URL is gone, publish anew and put the new URL here. On Codex, or without the Artifact tool,
   open the file: `open docs/map.html`.
3. **Show the project's own agents beside the plugin agents.** When the repository has a
   `.standards/config.json` whose `project.roster` names a roster file, render the page with a
   dashed "This project" group. This works from any project: the plugin ships the page
   (`assets/map.html`) and the script that fills it.
   ```
   python3 "<plugin root>/skills/map/scripts/project_map.py" --roster <project.roster> --out <scratch>/brain-map.html
   ```
   `<scratch>` is outside the repository: the session scratchpad on Claude, the system temp
   directory on Codex. Show that file instead of the shared page: on Claude publish it as a
   separate artifact, never over the shared URL; on Codex `open` it. In the marketplace
   checkout, `tools/map.sh --roster <file>` does the same from the sources. No
   `project.roster`: skip this step.
4. **Answer the question from the page's data**, not from memory: a skill's trigger line is the
   "Use when" sentence of its description, an agent's model and effort come from the roster.
   When the user asks "what do I run for X", name the skill and whether it runs on its own or
   needs to be called.

## Never

- Never edit `docs/map.html`; change the source it was rendered from and regenerate. The page
  with a project roster is a scratch copy: never commit it, never publish it over the shared URL.
- Never edit `assets/map.html`; it is a generated copy of `docs/map.html`.
- Never describe a skill the page does not list.
