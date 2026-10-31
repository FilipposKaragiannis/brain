#!/bin/sh
# Written by flow:init. Scheduled job: retro.sh <claude|codex> [args]. Logs to .flow/log/retro.log.
. "$(dirname "$0")/../plugin.sh"
exec "$FLOW_PLUGIN/jobs/retro.sh" "$@"
