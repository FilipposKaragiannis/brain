#!/bin/sh
# github in-scope <id>: exit 0 when the issue is inside github.scope (or no scope is set, with no
# call), 1 when it is outside, 2 for a scope scope_check in lib/flow.sh refuses, 3 when GitHub
# cannot say. The scope's kinds are matched on read.sh's item; the rest is its search (_query.py
# in-scope), paged up to github.limit.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 1 ] || die "usage: in-scope <id>" 2
scope_filter github
[ -n "$FLOW_SCOPE_ASSIGNEE$FLOW_SCOPE_STATUS$FLOW_SCOPE_LABELS$FLOW_SCOPE_KINDS$FLOW_SCOPE_QUERY" ] || exit 0
number="$(issue_number "$1")" || exit 2
if [ -n "$FLOW_SCOPE_KINDS" ]; then
  item="$("$FLOW_PLUGIN/adapters/github/read.sh" "$1")" || exit 3
  case ",$(printf '%s' "$FLOW_SCOPE_KINDS" | tr '[:upper:]' '[:lower:]')," in *,"$(json_get "$item" kind)",*) ;; *) exit 1 ;; esac
fi
FLOW_SCOPE_ASSIGNEE="$(assignee_login "$FLOW_SCOPE_ASSIGNEE")" || exit 3
cached_python3 -I "$FLOW_PLUGIN/adapters/github/_query.py" in-scope "$(gh_repo)" "$STATE_MARKER" "$number" "$(cfg_or github.limit 500)"
