#!/bin/sh
# A fake gh for the adapter tests. State lives in $FAKE_GH_DIR: issues.json and a call log.
# Covers the calls the GitHub adapter, the comments step and the PR step make, and nothing else.
# The evals reach it through tools/eval-bin/gh, with no _fake_gh.py beside the state.
log="$FAKE_GH_DIR/calls.log"; db="$FAKE_GH_DIR/issues.json"
py="$FAKE_GH_DIR/_fake_gh.py"; [ -f "$py" ] || py="$(dirname "$0")/_fake_gh.py"
printf '%s\n' "$*" >> "$log"
# $FAKE_GH_DIR/fail: "<N>" then a message on the second line; the next N calls fail with it.
fail="$FAKE_GH_DIR/fail"
if [ -s "$fail" ] && [ "$(head -n 1 "$fail")" -gt 0 ]; then
  printf '%s\n%s\n' "$(( $(head -n 1 "$fail") - 1 ))" "$(sed -n 2p "$fail")" > "$fail"
  sed -n 2p "$fail" >&2; exit 1
fi
python3 -I "$py" "$db" "$@"
