#!/bin/sh
# github list-ready [--kind KIND]: open issues with no open blocker and no gate.
. "$(dirname "$0")/_gh.sh"
"$FLOW_PLUGIN/adapters/github/list.sh" "$@" | "$FLOW_PLUGIN/scripts/filter-ready.sh"
