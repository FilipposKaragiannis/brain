#!/bin/sh
# jira list-ready [--kind KIND]: open issues with no open blocker, no gate and no field ready.needs
# asks for, best ready.priority_order rank first.
. "$(dirname "$0")/_jira.sh"
"$FLOW_PLUGIN/adapters/jira/list.sh" "$@" | "$FLOW_PLUGIN/scripts/filter-ready.sh"
