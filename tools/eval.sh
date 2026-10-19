#!/bin/sh
# Run a plugin's eval suite with the settings the suites need: scaffolded fixtures, the tools
# the skills have in production (Write and Edit included; a read-only case narrows them in its
# own execution.allowed_tools), and a judge model that reads long outputs correctly (the default
# judge fails long review reports). Costs money; not run in CI.
#   tools/eval.sh <plugin> [--baseline] [extra claude plugin eval flags]
# The default run has no baseline arm. --baseline runs only the cases tagged baseline (advisory
# skills plain Claude could attempt) twice, with and without the plugin, and reports the score
# delta; a case whose skill cannot work without the plugin is never tagged. `--tag negative`
# picks the should-not-trigger cases.
# After the run it prints tools/lib/eval_summary.py on the new aggregate-result.json: the
# scores over the runs that did not fail for an infrastructure reason (not logged in, a rate
# limit), which the CLI counts as 0, and those BLOCKED runs apart, each case next to its score
# in tools/eval-baseline.json. To move the baseline after a change you accept:
#   python3 tools/lib/eval_summary.py plugins/<plugin>/evals/results --save
# Every session runs with tools/eval-bin first on its PATH (the sandbox passes PATH on and reads
# the repo, not /tmp): gh on a case's fake state, launchctl and crontab that refuse, so no eval
# reaches GitHub or the machine's schedule. On macOS git and python3 that call the real binaries
# by path come first: /usr/bin/git and /usr/bin/python3 ask xcrun, which cannot write its cache
# in the sandbox, so git fails ("Failed to locate 'git'") and python3 prints errors.
# The exit status is the eval's.
set -eu
cd "$(dirname "$0")/.."
bin="$PWD/tools/.eval-bin"; mkdir -p "$bin"
for tool in git python3; do
  if real="$(xcrun --find "$tool" 2>/dev/null)"; then
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$bin/$tool"; chmod +x "$bin/$tool"
  else
    rm -f "$bin/$tool"
  fi
done
PATH="$bin:$PWD/tools/eval-bin:$PATH"; export PATH
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
claude plugin eval "plugins/$plugin" --scaffold --allow-tools Bash Read Glob Grep Agent Write Edit \
  --trust-plugin --no-publish $ablation --judge-model sonnet "$@" || status=$?
latest="$(find "$results" -name aggregate-result.json -newer "$marker" 2>/dev/null | sort | tail -1)"
if [ -n "$latest" ]; then
  python3 tools/lib/eval_summary.py "$latest" || true
else
  echo "eval summary: no new aggregate-result.json under $results"
fi
exit "$status"
