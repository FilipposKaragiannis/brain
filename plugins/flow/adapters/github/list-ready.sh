#!/bin/sh
# github list-ready [--kind KIND] [--pick NAME]: open issues with no open blocker and no gate; with
# --pick, only those the filter keeps (list.sh).
. "$(dirname "$0")/_gh.sh"
"$FLOW_PLUGIN/adapters/github/list.sh" "$@" | "$FLOW_PLUGIN/scripts/filter-ready.sh"
