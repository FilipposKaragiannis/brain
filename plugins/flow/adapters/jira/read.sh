#!/bin/sh
# jira read <id>: one issue as the adapter item JSON, whatever jira.scope says; its open children
# are counted inside the scope (scope_filter in lib/flow.sh), as list counts them.
. "$(dirname "$0")/_jira.sh"
ready_rules
[ $# -ge 1 ] || die "usage: read <id>" 2
scope_filter jira
jira read "$1"
