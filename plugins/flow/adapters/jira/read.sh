#!/bin/sh
# jira read <id>: one issue as the adapter item JSON.
. "$(dirname "$0")/_jira.sh"
ready_rules
[ $# -ge 1 ] || die "usage: read <id>" 2
jira read "$1"
