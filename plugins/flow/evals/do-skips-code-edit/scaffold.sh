#!/bin/sh
# Fixture: the flow step fixture (an item in progress), so a plain code request sits next to the
# flow's work items.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers" implement
