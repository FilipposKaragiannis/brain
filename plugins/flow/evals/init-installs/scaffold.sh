#!/bin/sh
# Fixture for the flow init eval: a repo with one linked worktree beside it, no GitHub remote.
# The eval CLI runs this in <run root>/home/cwd, so ../fixture-wt-1 stays inside the run's own
# directory. A failed worktree add fails the scaffold instead of leaving the pool path untested.
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
printf '# Project\n' > README.md
git add -A
git commit -qm init
git worktree add -q --detach ../fixture-wt-1
