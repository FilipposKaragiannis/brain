#!/bin/sh
# Fixture: the flow fixture; help reads the installed plugin, not the repo.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
