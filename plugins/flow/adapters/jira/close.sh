#!/bin/sh
# jira close <id> [--comment TEXT]: comment, then move the issue through the jira.transitions.done
# transition (default: the first one named Done).
. "$(dirname "$0")/_jira.sh"
[ $# -ge 1 ] || die "usage: close <id> [--comment TEXT]" 2
text=""; [ "${2:-}" = "--comment" ] && text="${3:-}"
jira close "$1" "$text"
