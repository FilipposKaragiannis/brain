#!/bin/sh
# local strip-state <id>: take the flow's state off the item file. Temporary: state.sh import
# --strip is its one caller, and it goes when write-state goes. It removes every state key of the
# frontmatter but size, which is the item's own size, and leaves workflow, assignee, the body and
# the comments. Prints the id when it removed a key, nothing when the file held none. Exit 2 for an
# id that is not local, 1 when the item cannot be read or written.
set -u
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -eq 1 ] || die "usage: strip-state <id>" "$EXIT_USAGE"
{ item_id_shaped "$1" && [ "$(adapter_for "$1")" = local ]; } || die "strip-state: not a local item id: $1" "$EXIT_USAGE"
cached_python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" strip-state "$(flow_home)" "$1"
