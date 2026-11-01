#!/bin/sh
# github read <id>: one issue as the adapter item JSON.
. "$(dirname "$0")/_gh.sh"
ready_rules
[ $# -ge 1 ] || die "usage: read <id>" 2
repo="$(gh_repo)"; n="$(issue_number "$1")" || exit 2
python3 -I "$FLOW_PLUGIN/adapters/github/_query.py" read "$repo" "$STATE_MARKER" "$n" | issue_to_item || die "cannot read $1"
