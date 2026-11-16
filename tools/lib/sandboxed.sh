#!/bin/sh
# sandboxed.sh <watched dir> <command...>: runs a test command in the sandbox of sandbox.sh, with a
# throwaway home and no git, Claude, Codex or flow pointer at a real checkout or config. Exits with
# the command's status, or 1 when the run changed the checkout it runs from or <watched dir>.
set -u
[ $# -ge 2 ] || { echo "usage: sandboxed.sh <watched dir> <command...>" >&2; exit 2; }
watched="$1"; shift
work="$(mktemp -d)"
. "$(dirname "$0")/sandbox.sh"; sandbox_enter "$work" "$watched"
trap 'sandbox_close $?' EXIT
"$@"
