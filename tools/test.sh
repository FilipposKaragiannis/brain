#!/bin/sh
# Run every check for this repo: lint, then plugin validation with the Claude CLI when present.
set -u
cd "$(dirname "$0")/.."
status=0
tools/lint.sh || status=1
plugins/standards/hooks/tests/run.sh || status=1
plugins/flow/tests/run.sh || status=1
plugins/meta/tests/run.sh || status=1
if command -v claude >/dev/null 2>&1; then
  for dir in plugins/*/; do
    [ -f "$dir/plugin.source.json" ] || continue
    claude plugin validate "$dir" >/dev/null 2>&1 || { echo "test: claude plugin validate failed: $dir"; claude plugin validate "$dir"; status=1; }
  done
  claude plugin validate .claude-plugin/marketplace.json >/dev/null 2>&1 || { echo "test: marketplace validate failed"; claude plugin validate .claude-plugin/marketplace.json; status=1; }
else
  echo "test: claude CLI not found, skipping plugin validate"
fi
[ "$status" -eq 0 ] && echo "test: ok"
exit $status
