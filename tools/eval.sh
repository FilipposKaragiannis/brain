#!/bin/sh
# Run a plugin's eval suite with the settings the suites need: scaffolded fixtures, the tools the
# cases list, and a judge model that reads long outputs correctly (the default judge fails long
# review reports). Costs money; not run in CI.
#   tools/eval.sh <plugin> [extra claude plugin eval flags]
set -eu
cd "$(dirname "$0")/.."
plugin="${1:?plugin name, e.g. standards}"; shift
exec claude plugin eval "plugins/$plugin" --scaffold --allow-tools Bash Read Glob Grep Agent \
  --trust-plugin --no-publish --ablation none --judge-model sonnet "$@"
