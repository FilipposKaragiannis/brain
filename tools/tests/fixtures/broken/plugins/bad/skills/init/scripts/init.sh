#!/bin/sh
# A broken installer for tools/tests/run.sh: lint must report missing.yaml only.
plugin="$(cd "$(dirname "$0")/../../.." && pwd)"
cp "$plugin/templates/config.yaml" .
cp "$plugin/templates/missing.yaml" .
for f in "$plugin"/templates/*.yaml; do echo "$f"; done
