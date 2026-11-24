#!/bin/sh
# jira me: the names `me` stands for in ready.assignee, one per line: the account id of the user
# the API token belongs to, then jira.email.
set -u
. "$(dirname "$0")/_jira.sh"
[ $# -eq 0 ] || die "usage: me" "$EXIT_USAGE"
jira me
