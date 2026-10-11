#!/bin/sh
# Fixture for the init eval: a small C# repo with a symlinked AGENTS.md, like the owner's projects.
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
mkdir -p AI/docs src/App
printf '# Project\n\nProject rules here.\n\n## Glossary\n- pin: a thing\n' > AI/docs/AGENTS.md
ln -s AI/docs/AGENTS.md AGENTS.md
printf 'Microsoft Visual Studio Solution File\n' > src/App.sln
printf 'class A {}\n' > src/App/A.cs
git add -A
git commit -qm init
