#!/bin/sh
# build-passed.sh: prints the run a kept pass of the project's build came from
# (`<time> <item> <head>`, lib/checks.sh) when verify passed the same build command on the same
# files as HEAD, so the standards pre-push hook skips a build that already passed. It runs through
# the .flow/build-passed.sh wrapper flow:init writes; the hook builds when the wrapper is missing.
# Exit 0 with the run printed; 1 with nothing printed when no pass is kept, the project has no
# build, its config cannot be read, or a file under the build's paths has an uncommitted change.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/checks.sh"
root="$(repo_root)" || exit 1
cd "$root" || exit 1
planned="$(python3 -I "$FLOW_PLUGIN/scripts/_checks.py" plan .standards/config.json 2>/dev/null)" || exit 1
build_command="$(json_get "$planned" build.0.command)"
[ -n "$build_command" ] || exit 1
check_passed "$(check_key "$build_command" "$(json_list "$planned" build.0.paths)")"
