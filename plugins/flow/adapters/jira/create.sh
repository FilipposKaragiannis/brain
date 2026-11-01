#!/bin/sh
# jira create <kind> <title> [--size S|M|L] [--priority NAME] [--area NAME] [--type NAME] [--blocked-by id,id] [--parent id] [--body TEXT]:
# a new issue; prints its id. The kind picks the issue type (jira.types.epic|task|bug, default Epic,
# Task, Bug) unless --type names one. The size goes to the jira.fields.size field when set, else a
# size: label; the area to jira.fields.area when set, else nowhere, said on stderr; the priority to
# Jira's priority. A parent is the issue's parent; a Jira blocker becomes a Blocks link, a blocker
# in another tracker a "Blocked by:" line in the description.
. "$(dirname "$0")/_jira.sh"
[ $# -ge 2 ] || die "usage: create <kind> <title> [--size S] [--priority P] [--area A] [--type T] [--blocked-by a,b] [--parent id] [--body TEXT]" 2
jira create "$@"
