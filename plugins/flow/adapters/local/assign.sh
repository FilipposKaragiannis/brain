#!/bin/sh
# local assign <id> <me|none>: add the first name `me` prints to the item file's assignee, or take
# it off, leaving any other name. Prints "<id> <name>" when it changed the file, nothing when the
# file already said so.
set -u
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -eq 2 ] || die "usage: assign <id> <me|none>" "$EXIT_USAGE"
{ item_id_shaped "$1" && [ "$(adapter_for "$1")" = local ]; } || die "assign: not a local item id: $1" "$EXIT_USAGE"
cached_python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" assign "$(flow_home)" "$@"
