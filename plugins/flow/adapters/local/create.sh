#!/bin/sh
# local create <kind> <title> [--size S|M|L] [--blocked-by id,id] [--body TEXT] [--labels a,b] [--parent id] [--area NAME] [--priority NAME]:
# a new item; prints its id. Local only: GitHub items are created with gh or in the browser.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 2 ] || die "usage: create <kind> <title> [--size S] [--blocked-by a,b] [--body TEXT]" 2
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" create "$(flow_home)" "$@"
