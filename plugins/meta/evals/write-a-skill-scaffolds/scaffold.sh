#!/bin/sh
# Fixture: a copy of the marketplace tools and one plugin, so write-a-skill can scaffold.
set -e
git init -q -b main .
git config user.email eval@example.com
git config user.name eval
mkdir -p plugins/demo/skills tools
printf '{"name":"demo","version":"0.1.0","description":"demo plugin","keywords":[],"codex":{"displayName":"Demo"},"skills":[]}\n' > plugins/demo/plugin.source.json
printf '# Demo marketplace\n' > README.md
git add -A && git commit -qm "chore: initial"
