---
name: write-a-skill
description: Create new agent skills with proper structure, progressive disclosure, and bundled resources. Use when user wants to create, write, or build a new skill.
---

# Writing Skills

## Process

1. **Gather requirements** - ask user about:
   - What task/domain does the skill cover?
   - What specific use cases should it handle?
   - Does it need executable scripts or just instructions?
   - Any reference materials to include?

2. **Draft the skill.** Apply the quality bar and vocabulary from [writing-great-skills](../writing-great-skills/SKILL.md) (and its [GLOSSARY.md](../writing-great-skills/GLOSSARY.md)) for every judgment call — model- vs. user-invoked, what stays in `SKILL.md` vs. what's disclosed to a separate file, how the description is worded, what to prune. This skill only adds the packaging mechanics that reference doesn't cover:
   - `SKILL.md` is required; add other `.md` files for disclosed reference, named for what they hold.
   - Add a `scripts/` utility script when an operation is deterministic (validation, formatting) or would otherwise regenerate the same code every run — scripts save tokens and improve reliability over generated code.

3. **Review with user** - present the draft and ask:
   - Does this cover your use cases?
   - Anything missing or unclear?
   - Should anything be disclosed elsewhere, or pulled back inline?

## Skill Structure

```
skill-name/
├── SKILL.md           # Main instructions (required)
├── REFERENCE.md        # Disclosed reference (if needed)
└── scripts/            # Utility scripts (if needed)
    └── helper.js
```
