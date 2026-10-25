#!/bin/sh
# Fixture for the install eval. Runs as you, in a fresh sandbox directory.
set -e
git init -q .
git config user.email eval@example.com
git config user.name eval
printf "# Fixture\n" > README.md
git add -A && git commit -qm init
