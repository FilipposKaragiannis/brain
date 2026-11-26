#!/bin/sh
# Fixture: the hot-path change, committed with two claimed numbers and nothing about how they were
# measured.
set -u
exec sh "$(dirname "$0")/fixture.sh" "perf(simulation): Step without LINQ

Step is 12% faster and allocates 0 bytes per call."
