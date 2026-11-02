#!/bin/sh
# jira list-ready [--kind KIND] [--pick NAME]: open issues with no open blocker, no gate and no
# field ready.needs asks for, best ready.priority_order rank first; with --pick, only those the
# filter keeps (list.sh).
. "$(dirname "$0")/_jira.sh"
"$FLOW_PLUGIN/adapters/jira/list.sh" "$@" | "$FLOW_PLUGIN/scripts/filter-ready.sh"
