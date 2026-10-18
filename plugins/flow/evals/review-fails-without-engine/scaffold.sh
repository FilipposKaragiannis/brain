#!/bin/sh
# Fixture: the item at its review step with a fix on the task branch, and the standards rules
# installed on main, which the task branch is rebased onto. The eval loads flow alone (the eval
# CLI loads no plugin outside the one under test), so the engine, standards:review, is missing:
# the step must fail with that reason and never grade the diff itself.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" review implemented
set -e
"$S/skills/init/scripts/init.sh" >/dev/null
git add -A && git -c core.hooksPath=/dev/null commit -qm "chore: install the standards [config]"
git -C .pool/wt-1 -c core.hooksPath=/dev/null rebase -q main
