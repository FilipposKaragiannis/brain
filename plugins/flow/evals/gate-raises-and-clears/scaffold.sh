#!/bin/sh
# Fixture: the flow fixture with the item at implement and its run released, so a gate can stop it.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
rm -f .flow/runs/*.json
