#!/bin/sh
# Fixture: the same hot-path change, committed with no number claimed anywhere.
set -u
exec sh "$(dirname "$0")/../perf-claim-asks-measurement-questions/fixture.sh" "perf(simulation): Step without LINQ"
