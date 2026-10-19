#!/bin/sh
# A fake gh for the adapter tests. State lives in $FAKE_GH_DIR: issues.json and a call log.
# Covers the calls the GitHub adapter, the comments step and the PR step make, and nothing else.
# The evals reach it through tools/eval-bin/gh, with no _fake_gh.py beside the state.
log="$FAKE_GH_DIR/calls.log"; db="$FAKE_GH_DIR/issues.json"
py="$FAKE_GH_DIR/_fake_gh.py"; [ -f "$py" ] || py="$(dirname "$0")/_fake_gh.py"
printf '%s\n' "$*" >> "$log"
python3 -I "$py" "$db" "$@"
