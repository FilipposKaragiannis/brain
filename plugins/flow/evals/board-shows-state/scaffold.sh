#!/bin/sh
# Fixture: local:task/1 claimed in wt-1 at implement, and local:task/2 waiting at an ambiguity gate.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
set -e
id="$("$P/adapters/local/create.sh" task "Greet in French" --size S --body "## Acceptance
- [ ] greet --fr prints bonjour <name>")"
"$P/scripts/gate.sh" raise "$id" ambiguity "1. Should greet --fr also greet a stranger in French?
   Recommended: yes, bonjour inconnu, so both acceptance lines hold in French." >/dev/null
