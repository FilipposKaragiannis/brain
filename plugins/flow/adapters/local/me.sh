#!/bin/sh
# local me: the names `me` stands for in a pick, local.scope or ready.assignee, one per line: the
# git user's email, then name, lower case. Nothing, and exit 0, when git has neither.
set -u
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -eq 0 ] || die "usage: me" "$EXIT_USAGE"
cached_python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" me "$(flow_home)"
