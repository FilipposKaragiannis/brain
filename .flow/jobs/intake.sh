#!/bin/sh
# Written by flow:init. Scheduled job: intake.sh <claude|codex> [args]. Logs to .flow/log/intake.log.
. "$(dirname "$0")/../plugin.sh"
exec "$FLOW_PLUGIN/jobs/intake.sh" "$@"
