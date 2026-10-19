#!/bin/sh
# Fixture: the flow fixture with no job scheduled. The prompt points jobs.sh at cron and at a
# launch agents folder inside the fixture; tools/eval.sh puts a launchctl and a crontab that
# refuse first on the PATH, so nothing reaches this machine's schedule either way.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
