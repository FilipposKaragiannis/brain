#!/bin/sh
# Fixture: the item at its pr step, but its last commit breaks the greeting and the verify report
# on the task branch fails. The PR step must stop: no push, no PR.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" pr implemented
set -e
github '{"issues": [], "pr": null}'
: > .fake-gh/calls.log
wt=.pool/wt-1
printf '#!/bin/sh\nprintf "hi %%s\\n" "${1:-stranger}"\n' > "$wt/src/greet.sh"
git -C "$wt" commit -qam "refactor(greet): shorter greeting"
(cd "$wt" && "$P/scripts/verify.sh" local:task/1 >/dev/null) || true
