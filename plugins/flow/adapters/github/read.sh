#!/bin/sh
# github read <id>: one issue as the adapter item JSON.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 1 ] || die "usage: read <id>" 2
repo="$(gh_repo)"; n="$(issue_number "$1")"
issue="$(gh issue view "$n" -R "$repo" --json number,title,body,state,labels,url)" || die "cannot read $1"
comment="$(state_comment "$repo" "$n")"
blockers="$(blocked_by "$repo" "$n")"
parent="$(parent_of "$repo" "$n")"; [ -n "$parent" ] || parent=null
printf '%s\n%s\n%s\n%s\n' "$issue" "$comment" "$blockers" "$parent" | python3 -I -c '
import json, sys
lines = sys.stdin.read().split("\n")
issue, comment, blockers, parent = (json.loads(l) for l in lines[:4])
issue["state_comment"] = comment["data"]; issue["blocked_by"] = blockers; issue["parent"] = parent
print(json.dumps(issue))' | issue_to_item
