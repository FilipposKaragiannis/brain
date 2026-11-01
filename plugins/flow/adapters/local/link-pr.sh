#!/bin/sh
# local link-pr <id> <pr-url>: record the PR on the item, with the host that wrote it (pr_host:
# claude or codex, the session this runs in).
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
author="$(host_name)"; case "$author" in claude|codex) ;; *) author="" ;; esac
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" write-state "$(flow_home)" "$1" "pr=$2" ${author:+"pr_host=$author"}
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" comment "$(flow_home)" "$1" "PR: $2"
