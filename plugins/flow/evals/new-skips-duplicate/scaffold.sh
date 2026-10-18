#!/bin/sh
# Fixture: the flow fixture, whose one open item (local:task/1) already asks for the greeting.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
