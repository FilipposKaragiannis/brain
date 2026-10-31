#!/bin/sh
# Written by flow:init. Scheduled job: comments.sh <claude|codex> [args]. Logs to .flow/log/comments.log.
. "$(dirname "$0")/../plugin.sh"
exec "$FLOW_PLUGIN/jobs/comments.sh" "$@"
