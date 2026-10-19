#!/bin/sh
# Fixture: the flow fixture, whose one open item (local:task/1) is about strangers, not shouting.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
