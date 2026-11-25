# answers.sh: which gated items the owner can answer on their tracker, from the flow records.
# Sourced after lib/flow.sh by jobs/next.sh and each adapter's answers.sh, never run.

# answerable_gates <adapter> [<item>...]: of the gate rows on stdin (record_list gates), each item
# of the adapter (its prefix file, as adapter_for routes it) at a gate the owner answers on the
# tracker, one per line: any gate but merge, which clears when its PR is merged. With items
# given, only those of them.
answerable_gates() {
  answer_prefix=""; read -r answer_prefix < "$FLOW_PLUGIN/adapters/$1/prefix" 2>/dev/null
  shift
  [ -n "$answer_prefix" ] || return 0
  cached_python3 -I -c '
import json, sys
prefix, given = sys.argv[1], set(sys.argv[2:])
for line in sys.stdin:
    row = json.loads(line) if line.strip() else {}
    item = row.get("item") or ""
    if item.startswith(prefix) and row.get("gate") != "merge" and (not given or item in given):
        print(item)' "$answer_prefix" "$@"
}

# answer_items_required <adapter> <item>...: refuses, exit 2, unless every item is of the
# adapter's shape: its slug.sed turns each item's slug back into the item, as item_id_shaped reads
# one id, here in one pass for all of them, before the adapter reads its tracker.
answer_items_required() {
  answer_required_adapter="$1"; shift
  answer_required_line_break="
"
  for answer_required_item in "$@"; do
    case "$answer_required_item" in *"$answer_required_line_break"*) die "answers takes $answer_required_adapter item ids, one per argument" 2 ;; esac
  done
  answer_required_given="$(printf '%s\n' "$@")"
  answer_required_shaped="$(item_slug "$answer_required_given" | sed -n -f "$FLOW_PLUGIN/adapters/$answer_required_adapter/slug.sed")"
  [ "$answer_required_shaped" = "$answer_required_given" ] || die "answers takes $answer_required_adapter item ids; given: $*" 2
}
