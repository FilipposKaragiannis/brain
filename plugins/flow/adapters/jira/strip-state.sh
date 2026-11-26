#!/bin/sh
# jira strip-state <id>: take the flow's state off the issue. Temporary: state.sh import --strip is
# its one caller, and it goes when write-state goes. It removes the step:, gate:, wt: and flow:
# labels and the flow-state property, and leaves the size: labels, the jira.fields.size field and
# the flow-transition-target property set-status keeps. Prints the id when it removed something,
# nothing when the issue was clean. Exit 2 for an id that is not Jira's, 1 when Jira fails.
set -u
. "$(dirname "$0")/_jira.sh"
[ $# -eq 1 ] || die "usage: strip-state <id>" "$EXIT_USAGE"
jira strip-state "$1"
