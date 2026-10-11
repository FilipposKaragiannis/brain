#!/bin/sh
# Fixture: a small shell project with a shallow pass-through layer and a glossary.
set -e
git init -q -b main .
git config user.email eval@example.com
git config user.name eval
mkdir -p src docs/adr
printf '# Project\n\n## Glossary\n**Order**: a confirmed request to buy.\n' > AGENTS.md
printf '#!/bin/sh\n# order_apply_discount <subtotal> <discount>: prints subtotal minus discount\norder_apply_discount() { echo "$(( $1 - $2 ))"; }\n' > src/order_apply_discount.sh
printf '#!/bin/sh\n# order_validate <subtotal>: exits 1 on a negative subtotal\norder_validate() { [ "$1" -ge 0 ]; }\n' > src/order_validate.sh
printf '#!/bin/sh\n# order_total <subtotal> <discount>: prints the total\norder_total() { order_apply_discount "$1" "$2"; }\n' > src/order_total.sh
printf '#!/bin/sh\n# order_format <total>: prints the total with a currency\norder_format() { printf "EUR %%s\\n" "$1"; }\n' > src/order_format.sh
printf '#!/bin/sh\n# order <subtotal> <discount>: validate, total, format\n. "$(dirname "$0")/order_validate.sh"; . "$(dirname "$0")/order_apply_discount.sh"; . "$(dirname "$0")/order_total.sh"; . "$(dirname "$0")/order_format.sh"\norder_validate "$1" || exit 1\norder_format "$(order_total "$1" "$2")"\n' > src/order.sh
git add -A && git commit -qm "chore: initial"
for i in 1 2 3; do printf '# change %s\n' "$i" >> src/order_total.sh; git commit -qam "feat: tweak $i"; done
