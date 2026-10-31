#!/bin/sh
# Written by flow:init. Scheduled job: next.sh <claude|codex> [args]. Logs to .flow/log/next.log.
. "$(dirname "$0")/../plugin.sh"
exec "$FLOW_PLUGIN/jobs/next.sh" "$@"
