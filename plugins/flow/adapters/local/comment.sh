#!/bin/sh
# local comment <id> [--body TEXT]: append a comment; the text comes from --body or stdin.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 1 ] || die "usage: comment <id> [--body TEXT]" 2
id="$1"; shift
if [ "${1:-}" = "--body" ]; then text="$2"; else text="$(cat)"; fi
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" comment "$(flow_home)" "$id" "$text"
