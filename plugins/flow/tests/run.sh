#!/bin/sh
# Runs the flow plugin's tests: hands the whole run to tools/lib/flow_suites.py, which runs every
# suite file in this folder in a sandbox of its own. Takes no argument; a usage error exits 2.
# Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
case "$#" in
  0) exec python3 -I "$here/../../../tools/lib/flow_suites.py" all ;;
  *) echo "usage: run.sh" >&2; exit 2 ;;
esac
