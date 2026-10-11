---
name: write-a-skill
description: Write a new agent skill to the house bar, with the right invocation, progressive disclosure, in-plugin links, an eval case and the plugin registration. Use when the user wants to create, write or package a skill, or when retro routes a finding to a new skill.
---

# Write a skill

A skill wrangles predictability out of a stochastic system: the same process every run. The
quality bar and the vocabulary are in [writing-great-skills](reference/writing-great-skills.md)
(terms in [GLOSSARY.md](reference/GLOSSARY.md)); this skill adds the packaging for this
marketplace and the hosts.

## Steps

1. **Pin the job.** One sentence: what the skill produces, for whom, and the leading word it
   thinks with. Decide the invocation: model-invoked only when the agent or another skill must
   reach it on its own; otherwise user-invoked. Done when the owner agrees with the sentence.
2. **Scaffold.** From the marketplace root:
   ```
   plugins/meta/skills/write-a-skill/scripts/scaffold.sh plugins/<plugin> <name> [--user] --short "<one line>"
   ```
   It writes `skills/<name>/SKILL.md`, `evals/<name>-works/` and the entry in
   `plugin.source.json`; `tools/generate.sh` then renders `agents/openai.yaml` (Codex reads the
   `invocation` flag from there; Claude from `disable-model-invocation`).
3. **Write the body.** Steps in order, each ending on a checkable completion criterion;
   reference on demand, long reference disclosed to a sibling file; one hard guardrail under
   `## Never`, phrased with what to do instead. Prune: no-ops, duplication, cached environment
   truth. Done when every sentence changes behaviour versus the default.
4. **Write the description.** Model-invoked: the leading word first, one trigger per branch, a
   reach clause when another skill calls it. User-invoked: one human-facing line.
5. **Write the eval.** `prompt.md` is a user message that should fire the skill without naming
   it (model-invoked) or the `/plugin:name` command (user-invoked); graders: `tool_used` on the
   Skill tool, a `regex` or `file_exists` on the promised output, one `llm` rubric on the final
   message. A fixture goes in `scaffold.sh`. Done when `tools/eval.sh <plugin>` passes.
6. **Review with the owner.** Show the skill and the eval; ask what is missing or unclear and
   what should move up or down the ladder.

## House rules

- Frontmatter `name` equals the folder name; lint checks it, and the invocation flag.
- Links stay inside the plugin: `../other-skill/FILE.md` is fine, `../../other-plugin/` is not
  (plugins install separately on both hosts). Lint checks that every relative link resolves.
- Scripts are POSIX sh, python3 at most; no `${CLAUDE_PLUGIN_ROOT}` inside a SKILL.md command
  (Codex has no such variable): say "the plugin root is the directory holding this skill".
- Plain English in the body: one idea per sentence, the project's words, no code in prose.
- A skill that is a step of the flow lives in `flow`; a rule lives in the standards file.

## Never

- Never ship a skill without an eval case; a skill nobody can test is a skill nobody can change.
