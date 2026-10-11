#!/bin/sh
# Fixture for the flow init eval: a repo with one linked worktree, no GitHub remote.
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
printf '# Project\n' > README.md
git add -A
git commit -qm init
git worktree add -q --detach ../fixture-wt-1 2>/dev/null || true
