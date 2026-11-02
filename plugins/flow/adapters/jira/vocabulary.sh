#!/bin/sh
# jira vocabulary: the names a new item may use, as JSON: {"types": [...], "areas": [...]}. Types
# are the project's issue types (no sub-tasks); areas the options of the jira.fields.area field
# where a new task picks it, none when the field is unset or takes free text.
. "$(dirname "$0")/_jira.sh"
[ $# -eq 0 ] || die "usage: vocabulary" 2
jira vocabulary
