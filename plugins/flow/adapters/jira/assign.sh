#!/bin/sh
# jira assign <id> <me|none>: set the assignee to the user the API token belongs to, or clear it when
# that user holds the issue. Jira holds one assignee, so me leaves an issue someone else holds with
# them. Prints "<id> <account id>" when it changed the issue, nothing when it already said so.
set -u
. "$(dirname "$0")/_jira.sh"
[ $# -eq 2 ] || die "usage: assign <id> <me|none>" "$EXIT_USAGE"
jira assign "$@"
