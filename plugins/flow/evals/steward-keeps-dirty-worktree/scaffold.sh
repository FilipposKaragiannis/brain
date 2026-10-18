#!/bin/sh
# Fixture: the item has wt-1 claimed, with an edit to src/greet.sh that is not committed.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
printf '#!/bin/sh\n# work in progress\nprintf "hello %%s\\n" "${1:-friend}"\n' > .pool/wt-1/src/greet.sh
