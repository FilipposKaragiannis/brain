#!/bin/sh
# Run the checks of this repo. `tools/test.sh` runs every part, as CI and a person do.
# `tools/test.sh <part>...` runs only the parts named: verify runs the parts a change can affect,
# from `test` in .standards/config.json, which gives each part its paths. Parts: lint, standards,
# flow, meta, console, tools, console-app, and plugins (plugin validation and the always-on token
# cost report with the Claude CLI when present). Exit 2 on a name that is no part.
set -u
cd "$(dirname "$0")/.."
every_part="lint standards flow meta console tools console-app plugins"
parts="$every_part"; [ $# -eq 0 ] || parts="$*"
status=0
# The suites run in an empty environment, so nothing the owner exports (a Slack webhook, a token)
# reaches them. Each suite also stubs the network, desktop and agent tools itself.
clean() { env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" "$@"; }
# A part whose tools are missing: the whole run skips it, as CI's test job has no Node and a job
# of its own runs the console app; a part named on the command line fails, so a check that names
# it never passes on a suite that did not run.
when_missing=skip; [ $# -eq 0 ] || when_missing=fail
# cannot_run <part> <what is missing> <what provides it>: says so, and 1 when the part was named.
cannot_run() {
  if [ "$when_missing" = skip ]; then echo "test: $2 missing, skipping $1"; return 0; fi
  echo "test: $1 cannot run, $2 missing; $3" >&2; return 1
}

# The console app (plugins/console/app): the daemon's type-check and suite, then the UI's, when Node 24 and both sets of dev dependencies are present.
console_app() {
  console=plugins/console/app
  command -v node >/dev/null 2>&1 || { cannot_run console-app node "install Node 24"; return; }
  if [ ! -d $console/node_modules ] || [ ! -d $console/ui/node_modules ]; then
    cannot_run console-app "$console/node_modules or $console/ui/node_modules" "run: cd $console && npm ci && cd ui && npm ci"; return
  fi
  (cd $console && npm run --silent check)
}

plugins_valid() {
  command -v claude >/dev/null 2>&1 || { cannot_run plugins "the claude CLI" "install Claude Code: npm install -g @anthropic-ai/claude-code"; return; }
  validated=0
  for dir in plugins/*/; do
    [ -f "$dir/plugin.source.json" ] || continue
    claude plugin validate --strict "$dir" >/dev/null 2>&1 || { echo "test: claude plugin validate failed: $dir"; claude plugin validate --strict "$dir"; validated=1; }
  done
  claude plugin validate --strict .claude-plugin/marketplace.json >/dev/null 2>&1 || { echo "test: marketplace validate failed"; claude plugin validate --strict .claude-plugin/marketplace.json; validated=1; }
  tools/cost.sh || true   # a report with warnings, never a failure
  return "$validated"
}

for part in $parts; do
  case "$part" in
    lint) tools/lint.sh || status=1 ;;
    standards)
      clean plugins/standards/hooks/tests/run.sh || status=1
      clean plugins/standards/hooks/tests/file-names.sh || status=1
      clean plugins/standards/hooks/tests/testing-guide.sh || status=1
      ;;
    flow) clean plugins/flow/tests/run.sh || status=1 ;;
    meta) clean plugins/meta/tests/run.sh || status=1 ;;
    console) clean plugins/console/tests/run.sh || status=1 ;;
    tools) clean tools/tests/run.sh || status=1 ;;
    console-app) console_app || status=1 ;;
    plugins) plugins_valid || status=1 ;;
    *) echo "test: no part named $part; the parts are $every_part" >&2; exit 2 ;;
  esac
done
[ "$status" -eq 0 ] && echo "test: ok"
exit $status
