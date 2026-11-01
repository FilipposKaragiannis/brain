#!/bin/sh
# jira list [--all] [--kind KIND]: the project's open issues (all with --all) as adapter items.
# Stops at jira.limit (default 500) and says so. With FLOW_LIST_WHOLE set, a cut list fails.
. "$(dirname "$0")/_jira.sh"
ready_rules
jira list "$@"
