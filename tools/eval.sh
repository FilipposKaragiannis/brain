#!/bin/sh
# Run a plugin's eval suite with the settings the suites need: scaffolded fixtures, the tools the
# cases list, and a judge model that reads long outputs correctly (the default judge fails long
# review reports). Costs money; not run in CI.
#   tools/eval.sh <plugin> [--baseline] [extra claude plugin eval flags]
# The default run has no baseline arm. --baseline runs only the cases tagged baseline (advisory
# skills plain Claude could attempt) twice, with and without the plugin, and reports the score
# delta; a case whose skill cannot work without the plugin is never tagged. `--tag negative`
# picks the should-not-trigger cases.
# After the run it prints tools/lib/eval_summary.py on the new aggregate-result.json: the
# scores over the runs that did not fail for an infrastructure reason (not logged in, a rate
# limit), which the CLI counts as 0, and those BLOCKED runs apart. The exit status is the eval's.
set -eu
cd "$(dirname "$0")/.."
plugin="${1:?plugin name, e.g. standards}"; shift
ablation="--ablation none"
if [ "${1:-}" = "--baseline" ]; then
  shift
  ablation="--ablation with-without --tag baseline"
fi
results="plugins/$plugin/evals/results"
prev=""
for arg in "$@"; do
  [ "$prev" = "--output-dir" ] && results="$arg"
  prev="$arg"
done
marker="$(mktemp)"; trap 'rm -f "$marker"' EXIT
status=0
# shellcheck disable=SC2086
claude plugin eval "plugins/$plugin" --scaffold --allow-tools Bash Read Glob Grep Agent \
  --trust-plugin --no-publish $ablation --judge-model sonnet "$@" || status=$?
latest="$(find "$results" -name aggregate-result.json -newer "$marker" 2>/dev/null | sort | tail -1)"
if [ -n "$latest" ]; then
  python3 tools/lib/eval_summary.py "$latest" || true
else
  echo "eval summary: no new aggregate-result.json under $results"
fi
exit "$status"
