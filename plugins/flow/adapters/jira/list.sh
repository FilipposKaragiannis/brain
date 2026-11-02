#!/bin/sh
# jira list [--all] [--kind KIND] [--pick NAME]: the project's open issues (all with --all) as
# adapter items. Stops at jira.limit (default 500) and says so. With FLOW_LIST_WHOLE set, a cut list
# fails. --pick keeps the issues the filter pick.<name> matches (pick_filter in lib/flow.sh), as JQL
# on the assignee (me is currentUser(), the jira.email login), status and labels, and on the kind,
# or its query as a JQL condition.
. "$(dirname "$0")/_jira.sh"
ready_rules
pick_filter jira "$@" || { echo '[]'; exit 0; }
jira list "$@"
