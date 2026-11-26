#!/bin/sh
# github read <id>: one issue as the adapter item JSON.
. "$(dirname "$0")/_gh.sh"
ready_rules
[ $# -ge 1 ] || die "usage: read <id>" 2
repository="$(gh_repo)"; issue="$(issue_number "$1")" || exit 2
# No logins fail the read in _query.py, which says why.
state_authors="$(trusted_logins)" || state_authors=""
cached_python3 -I "$FLOW_PLUGIN/adapters/github/_query.py" read "$repository" "$STATE_MARKER" "$issue" "$state_authors" | issue_to_item || die "cannot read $1"
