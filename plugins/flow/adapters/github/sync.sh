#!/bin/sh
# github sync [id]: move the project card of one item, or of every open item, to the Status its
# flow state implies (see _mutate.py). Prints one line per card it moved. A no-op without
# github.project in .flow/config.yaml.
. "$(dirname "$0")/_gh.sh"
[ -n "$GH_PROJECT" ] || exit 0
if [ $# -ge 1 ]; then "$FLOW_PLUGIN/adapters/github/read.sh" "$1"
else "$FLOW_PLUGIN/adapters/github/list.sh" | python3 -I -c 'import json,sys; [print(json.dumps(i)) for i in json.load(sys.stdin)]'
fi | project_sync
