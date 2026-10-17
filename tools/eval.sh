#!/bin/sh
# Run a plugin's eval suite with the settings the suites need: scaffolded fixtures, the tools the
# cases list, and a judge model that reads long outputs correctly (the default judge fails long
# review reports). Costs money; not run in CI.
#   tools/eval.sh <plugin> [--baseline] [extra claude plugin eval flags]
# The default run has no baseline arm. --baseline runs only the cases tagged baseline (advisory
# skills plain Claude could attempt) twice, with and without the plugin, and reports the score
# delta; a case whose skill cannot work without the plugin is never tagged. `--tag negative`
# picks the should-not-trigger cases.
set -eu
cd "$(dirname "$0")/.."
plugin="${1:?plugin name, e.g. standards}"; shift
ablation="--ablation none"
if [ "${1:-}" = "--baseline" ]; then
  shift
  ablation="--ablation with-without --tag baseline"
fi
# shellcheck disable=SC2086
exec claude plugin eval "plugins/$plugin" --scaffold --allow-tools Bash Read Glob Grep Agent \
  --trust-plugin --no-publish $ablation --judge-model sonnet "$@"
