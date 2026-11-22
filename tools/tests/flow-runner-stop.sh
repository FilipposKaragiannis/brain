#!/bin/sh
# Tests that a TERM, INT or HUP stops Brain's Flow suite runner in time and leaves no suite
# behind: builds the throwaway project and hands it to flow_runner_stop.py. Takes no argument.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
tools="$root/tools"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

# shellcheck source=tools/tests/_flow_project_fixture.sh
. "$here/_flow_project_fixture.sh"
# shellcheck source=plugins/flow/lib/verify.sh
verify_stop_grace_seconds="$(FLOW_PLUGIN="$root/plugins/flow"; . "$root/plugins/flow/lib/verify.sh"; echo "$VERIFY_STOP_GRACE")"
python3 -I -B "$here/flow_runner_stop.py" "$project" "$base" "$work" "$verify_stop_grace_seconds"
