#!/bin/sh
# Fold each plugin's changelog fragments (plugins/<plugin>/changelog.d/*.md) into a release:
# the version, the CHANGELOG section, the generated files. Usage: tools/release.sh [--dry-run]
# [plugin ...]. See docs/adr/0002-changelog-fragments.md.
set -eu
cd "$(dirname "$0")/.."
exec python3 tools/lib/release.py "$@"
