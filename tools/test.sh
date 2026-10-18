#!/bin/sh
# Run every check for this repo: lint, the test suites, then plugin validation and the always-on
# token cost report with the Claude CLI when present.
set -u
cd "$(dirname "$0")/.."
status=0
tools/lint.sh || status=1
# The suites run in an empty environment, so nothing the owner exports (a Slack webhook, a token)
# reaches them. Each suite also stubs the network, desktop and agent tools itself.
clean() { env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" "$@"; }
clean plugins/standards/hooks/tests/run.sh || status=1
clean plugins/flow/tests/run.sh || status=1
clean plugins/meta/tests/run.sh || status=1
clean tools/tests/run.sh || status=1
if command -v claude >/dev/null 2>&1; then
  for dir in plugins/*/; do
    [ -f "$dir/plugin.source.json" ] || continue
    claude plugin validate "$dir" >/dev/null 2>&1 || { echo "test: claude plugin validate failed: $dir"; claude plugin validate "$dir"; status=1; }
  done
  claude plugin validate .claude-plugin/marketplace.json >/dev/null 2>&1 || { echo "test: marketplace validate failed"; claude plugin validate .claude-plugin/marketplace.json; status=1; }
  tools/cost.sh || true   # a report with warnings, never a failure
else
  echo "test: claude CLI not found, skipping plugin validate"
fi
[ "$status" -eq 0 ] && echo "test: ok"
exit $status
