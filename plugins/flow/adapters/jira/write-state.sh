#!/bin/sh
# jira write-state <id> key=value...: labels for step, gate, worktree (wt:), profile (flow:) and size
# (the jira.fields.size field instead, when set), as the GitHub adapter keeps them; the whole state
# in the issue property flow-state. Lists are comma-separated; an unknown key exits 2.
. "$(dirname "$0")/_jira.sh"
[ $# -ge 2 ] || die "usage: write-state <id> key=value..." 2
jira write-state "$@"
