#!/bin/sh
# Render all generated files (manifests, marketplaces, agents) from the sources.
set -eu
cd "$(dirname "$0")/.."
exec python3 tools/lib/generate.py "$@"
