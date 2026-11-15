#!/bin/sh
. "$(dirname "$0")/../_scaffold-common.sh"
# Size L: the design step runs the architect, and so writes design.md, only for L tasks and epics.
scaffold task L "Greet strangers" design
