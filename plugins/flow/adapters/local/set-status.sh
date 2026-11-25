#!/bin/sh
# local set-status <id> <backlog|ready|in-progress|needs-you|in-review>: write the item file's
# workflow, which its category reads. Prints "<id> <status>" when it changed the file, nothing when
# the file already said so.
set -u
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -eq 2 ] || die "usage: set-status <id> <backlog|ready|in-progress|needs-you|in-review>" "$EXIT_USAGE"
{ item_id_shaped "$1" && [ "$(adapter_for "$1")" = local ]; } || die "set-status: not a local item id: $1" "$EXIT_USAGE"
cached_python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" set-status "$(flow_home)" "$@"
