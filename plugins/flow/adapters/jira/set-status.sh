#!/bin/sh
# jira set-status <id> <backlog|ready|in-progress|needs-you|in-review>: move the issue through the
# jira.transitions.<name> transition; unset, ready takes the first transition into the status
# category new and in-progress the first into indeterminate. Prints "<id> <status>" when it moved
# the issue, nothing when it was there already or no transition leads there, which events.log says
# once.
set -u
. "$(dirname "$0")/_jira.sh"
[ $# -eq 2 ] || die "usage: set-status <id> <backlog|ready|in-progress|needs-you|in-review>" "$EXIT_USAGE"
jira set-status "$1" "$2" "$(flow_home)/events.log" "$(now_iso)"
