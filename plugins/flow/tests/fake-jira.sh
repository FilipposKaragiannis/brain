#!/bin/sh
# A fake curl for the Jira adapter tests: a small Jira Cloud whose state lives in
# $FAKE_JIRA_DIR/jira.json (_fake_jira.py), and a call log in calls.log. It answers only the REST v3
# calls the adapter makes, with the status after the body as -w "\n%{http_code}" prints it.
# $FAKE_JIRA_DIR/fail: line 1 a count N, line 2 an HTTP status, line 3 optional, a pattern for
# grep; the next N calls (that match the pattern) answer that status and change nothing, as a Jira
# having a bad minute does.
log="$FAKE_JIRA_DIR/calls.log"; db="$FAKE_JIRA_DIR/jira.json"
py="$FAKE_JIRA_DIR/_fake_jira.py"; [ -f "$py" ] || py="$(dirname "$0")/_fake_jira.py"
printf '%s\n' "$*" >> "$log"
fail="$FAKE_JIRA_DIR/fail"
if [ -s "$fail" ] && [ "$(sed -n 1p "$fail")" -gt 0 ] && printf '%s\n' "$*" | grep -q -- "$(sed -n 3p "$fail")"; then
  printf '%s\n%s\n%s\n' "$(( $(sed -n 1p "$fail") - 1 ))" "$(sed -n 2p "$fail")" "$(sed -n 3p "$fail")" > "$fail"
  cat >/dev/null
  printf '{"errorMessages": ["Service Unavailable"]}\n%s' "$(sed -n 2p "$fail")"; exit 0
fi
exec python3 -I "$py" "$db" "$@"
