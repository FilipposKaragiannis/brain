#!/bin/sh
# jira in-scope <id>: exit 0 when the issue is inside jira.scope (or no scope is set, with no
# call), 1 when it is outside, 2 for a scope scope_check in lib/flow.sh refuses; one search of the
# issue's key ANDed with the scope, then the scope's kinds on the issue type.
. "$(dirname "$0")/_jira.sh"
[ $# -ge 1 ] || die "usage: in-scope <id>" 2
scope_filter jira
jira in-scope "$1"
