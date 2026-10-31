#!/bin/sh
# Written by flow:init. Scheduled job: health.sh <claude|codex> [args]. Logs to .flow/log/health.log.
. "$(dirname "$0")/../plugin.sh"
exec "$FLOW_PLUGIN/jobs/health.sh" "$@"
