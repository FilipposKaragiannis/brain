#!/bin/sh
# A fake gh for the adapter tests. State lives in $FAKE_GH_DIR: issues.json and a call log.
# Covers the calls the GitHub adapter, the comments step and the PR step make, and nothing else.
# The evals reach it through tools/eval-bin/gh, with no _fake_gh.py beside the state.
log="$FAKE_GH_DIR/calls.log"; db="$FAKE_GH_DIR/issues.json"
py="$FAKE_GH_DIR/_fake_gh.py"; [ -f "$py" ] || py="$(dirname "$0")/_fake_gh.py"
printf '%s\n' "$*" >> "$log"
# $FAKE_GH_DIR/fail: line 1 a count N, line 2 the message; the next N calls fail with it, the
# body on stdout like gh api. Line 3, when there, limits that to calls whose arguments match it
# (grep -E); line 4 "landed" applies the call first, like a write GitHub took before the answer was lost.
fail="$FAKE_GH_DIR/fail"
if [ -s "$fail" ] && [ "$(sed -n 1p "$fail")" -gt 0 ] && { [ -z "$(sed -n 3p "$fail")" ] || printf '%s' "$*" | grep -Eq "$(sed -n 3p "$fail")"; }; then
  printf '%s\n%s\n%s\n%s\n' "$(( $(sed -n 1p "$fail") - 1 ))" "$(sed -n 2p "$fail")" "$(sed -n 3p "$fail")" "$(sed -n 4p "$fail")" > "$fail"
  [ "$(sed -n 4p "$fail")" = landed ] && python3 -I "$py" "$db" "$@" >/dev/null
  echo '{"message": "Server Error"}'; sed -n 2p "$fail" >&2; exit 1
fi
python3 -I "$py" "$db" "$@"
