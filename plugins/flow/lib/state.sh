#!/bin/sh
# The flow record of an item: one JSON file per item under state.dir that holds its workflow
# state, opened only by scripts/_state.py. Sourced by lib/flow.sh; defines functions and runs
# nothing. No public function changes a variable of its caller or reads its stdin (but items_join,
# whose input it is), and each returns its code rather than exiting the caller.
#   state_dir                   state.dir: absolute as given, relative under the main worktree;
#                               unset, <flow home>/state
#   record_file <item>          <state dir>/<slug>.json; closed/<slug>.json once archived
#   tracker_state               tracker_state in the config, else FLOW_TRACKER_STATE: labels (the
#                               default) or none; another value is refused, exit 2
#   flow_machine                this machine's name: FLOW_MACHINE, else hostname -s
#   record_get <item> <key>     one of the twenty-one state keys through the key map (gate reads none
#                               when clear), or a record path (gate.options.0.label, claim.machine);
#                               a string raw, anything else as JSON, nothing with no record
#   record_show <item>          the record as JSON; exit 1 with none
#   record_set <item> <pair>... key=value for the twenty-one keys (adapters/README.md; a dash reads as
#                               an underscore), or the record pairs run:=<object|null>,
#                               run.step=<text> and gate:=<object>, never both kinds in one write.
#                               With tracker_state labels the state pairs go to the tracker first
#                               (adapter write-state) and are recorded only when it took them.
#                               The run file, the gate file and the claim's step follow a write
#                               that names them (scripts/_state_views.py).
#                               Prints nothing on stdout. Exit 0 written; the adapter's code when
#                               the tracker refused, nothing written; 1 a record that does not
#                               parse; 2 a refused pair, item or config, nothing written; 75 the
#                               item's lock stayed busy. On 1 and 75 the tracker may have taken
#                               the write: stderr names the keys and the same call again is safe
#   record_set_with_claim <claim file> <item> <pair>...
#                               record_set for a caller that knows the item's claim.json, or empty
#                               when the item holds no pool worktree
#   item_claim_file <item>      the claim.json of the item's pool worktree; nothing when it holds
#                               none
#   take_item <item>            this machine holds the item: claim.machine, claim.host and
#                               claim.claimed_at, when the claim names no machine yet
#   record_archive <item>       the record to closed/; nothing with no record; exit 1 when
#                               another machine holds it
#   item_read <item>            the adapter's read of the item with its record joined on as state
#                               (scripts/_state_join.py: all twenty-one keys, a record winning whole),
#                               stamped state_from record, tracker or none. With no record its state
#                               is the tracker's under labels and empty under none; an archived
#                               record counts as none. The adapter's code when its read fails (2 for
#                               an id no adapter owns); 1 a record that does not parse, named
#   items_join                  item_read's join of the item, or array of items, on stdin, in one
#                               process; an item whose record does not parse is left out of an
#                               array and named on stderr
#   items_listed <adapter> [<argument>...]
#                               adapter list, joined as items_join does; the adapter's code when
#                               its list fails
#   record_list <runs|gates> [<item>]
#                               one compact row per line, by slug, of each run in flight
#                               ({"item", ...run}) or each gate notify.sh raised ({"gate", "item",
#                               ...}; a gate named alone has none); under labels an item with no
#                               record lists its run or gate file. A record that does not parse is
#                               left out and named on stderr
#   run_record <item>           the item's run row; nothing with none; 1 a record that does not parse
#   gate_record <item>          the item's gate row; nothing with none; 1 a record that does not parse
#   record_linked_pr <item>     the pr and pr_host link-pr left on the tracker, copied into the
#                               record; prints the PR, nothing when the tracker holds none. The
#                               adapter's code when its read fails; record_set's when the write does
# With no record yet, record_set and take_item start one from the tracker's state (lazy seed).
# record_get, record_show, record_set, take_item, record_archive, record_list with an item,
# run_record, gate_record and record_linked_pr refuse, exit 2, an id that is not of its adapter's
# shape (item_id_shaped).

EXIT_USAGE=2

state_dir() (
  flow_record_dir="$(cfg state.dir)"
  case "$flow_record_dir" in
    "") printf '%s/state' "$(flow_home)" ;;
    /*) printf '%s' "$flow_record_dir" ;;
    *) printf '%s/%s' "$(dirname "$(flow_home)")" "$flow_record_dir" ;;
  esac
)

record_file() { printf '%s/%s.json' "$(state_dir)" "$(item_slug "$1")"; }

tracker_state() (
  flow_record_tracker_state="$(cfg tracker_state)"
  flow_record_tracker_state="${flow_record_tracker_state:-${FLOW_TRACKER_STATE:-labels}}"
  case "$flow_record_tracker_state" in
    labels|none) printf '%s' "$flow_record_tracker_state" ;;
    *) die "tracker_state (.flow/config.yaml, else FLOW_TRACKER_STATE) is labels or none, not $flow_record_tracker_state" "$EXIT_USAGE" ;;
  esac
)

flow_machine() { printf '%s' "${FLOW_MACHINE:-$(hostname -s)}"; }

record_get() (
  [ $# -eq 2 ] || die "usage: record_get <item> <key>" "$EXIT_USAGE"
  item_shape_required "$1"
  state_python get "$(state_dir)" "$(flow_home)" "$1" -- "$2"
)

record_show() (
  [ $# -eq 1 ] || die "usage: record_show <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  state_python show "$(state_dir)" "$(flow_home)" "$1"
)

record_set() (
  [ $# -ge 2 ] || die "usage: record_set <item> <key=value>..." "$EXIT_USAGE"
  item_shape_required "$1"
  record_set_with_claim "$(record_claim_file "$@")" "$@"
)

record_set_with_claim() (
  [ $# -ge 3 ] || die "usage: record_set_with_claim <claim file> <item> <key=value>..." "$EXIT_USAGE"
  flow_record_claim_file="$1"; shift
  item_shape_required "$1"
  flow_record_item="$1"; shift
  flow_record_kind="$(record_pairs_kind "$@")" || exit "$EXIT_USAGE"
  flow_record_home="$(flow_home)"
  flow_record_dir="$(record_ensured_dir)" || exit "$EXIT_USAGE"
  flow_record_tracker="$(tracker_state)" || exit "$EXIT_USAGE"
  if [ "$flow_record_tracker" = labels ] && [ "$flow_record_kind" = state ]; then
    tracker_mirror "$flow_record_item" "$@" || exit
  fi
  record_seeded set "$flow_record_item" "$flow_record_dir" "$flow_record_home" \
    --claim-file "$flow_record_claim_file" -- "$@"
)

take_item() (
  [ $# -eq 1 ] || die "usage: take_item <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  flow_record_dir="$(record_ensured_dir)" || exit "$EXIT_USAGE"
  record_seeded take "$1" "$flow_record_dir" "$(flow_home)"
)

record_archive() (
  [ $# -eq 1 ] || die "usage: record_archive <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  state_python archive "$(state_dir)" "$(flow_home)" "$1" --machine "$(flow_machine)"
)

item_read() (
  [ $# -eq 1 ] || die "usage: item_read <item>" "$EXIT_USAGE"
  flow_record_read="$( (adapter read "$1") </dev/null)" || exit
  printf '%s' "$flow_record_read" | items_join
)

items_join() (
  [ $# -eq 0 ] || die "usage: items_join (an item or an array of items on stdin)" "$EXIT_USAGE"
  state_reader join
)

items_listed() (
  [ $# -ge 1 ] || die "usage: items_listed <adapter> [<argument>...]" "$EXIT_USAGE"
  flow_record_listed="$( (adapter list "$@") </dev/null)" || exit
  printf '%s' "$flow_record_listed" | items_join
)

record_list() (
  case "$#:${1:-}" in
    1:runs|1:gates) state_reader list --kind "$1" </dev/null ;;
    2:runs|2:gates) item_shape_required "$2"; state_reader list --kind "$1" --item "$2" </dev/null ;;
    *) die "usage: record_list <runs|gates> [<item>]" "$EXIT_USAGE" ;;
  esac
)

run_record() (
  [ $# -eq 1 ] || die "usage: run_record <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  state_reader row --kind runs --item "$1" </dev/null
)

gate_record() (
  [ $# -eq 1 ] || die "usage: gate_record <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  state_reader row --kind gates --item "$1" </dev/null
)

record_linked_pr() (
  [ $# -eq 1 ] || die "usage: record_linked_pr <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  flow_record_tracker_item="$( (adapter read "$1") </dev/null)" || exit
  flow_record_pr="$(json_get "$flow_record_tracker_item" state.pr)"
  [ -n "$flow_record_pr" ] || exit 0
  record_set "$1" "pr=$flow_record_pr" "pr_host=$(json_get "$flow_record_tracker_item" state.pr_host)" </dev/null || exit
  printf '%s\n' "$flow_record_pr"
)

# state_reader <command> [<option>...]: one _state.py read that joins or lists, in this flow home
# and tracker_state.
state_reader() {
  flow_record_reader_tracker="$(tracker_state)" || return "$EXIT_USAGE"
  cached_python3 -I "$FLOW_PLUGIN/scripts/_state.py" "$@" --state-dir "$(state_dir)" --flow-home "$(flow_home)" \
    --tracker-state "$flow_record_reader_tracker"
}

# item_shape_required <item>: refuses, exit 2, an id that is not of its adapter's shape.
item_shape_required() {
  item_id_shaped "$1" || die "$1 is no item id of an adapter's shape, so it has no record" "$EXIT_USAGE"
}

# state_python <command> <state dir> <flow home> <item> [<option>...]: one _state.py call on the
# item's record.
state_python() {
  flow_record_python_command="$1"; flow_record_python_dir="$2"; flow_record_python_home="$3"
  flow_record_python_item="$4"; shift 4
  cached_python3 -I "$FLOW_PLUGIN/scripts/_state.py" "$flow_record_python_command" \
    --state-dir "$flow_record_python_dir" --flow-home "$flow_record_python_home" \
    --item "$flow_record_python_item" "$@"
}

# tracker_mirror <item> <pair>...: the one adapter write-state call of the flow.
tracker_mirror() ( adapter write-state "$@" ) </dev/null >&2

# record_pairs_kind <pair>...: state or record, the kind every pair is; refuses, exit 2, a pair
# record_pair_kind refuses and the two kinds together.
record_pairs_kind() (
  flow_record_kind=""
  for flow_record_pair in "$@"; do
    flow_record_pair_kind="$(record_pair_kind "$flow_record_pair")" || exit "$EXIT_USAGE"
    [ "${flow_record_kind:-$flow_record_pair_kind}" = "$flow_record_pair_kind" ] \
      || die "a write holds state pairs or record pairs, never both: $*" "$EXIT_USAGE"
    flow_record_kind="$flow_record_pair_kind"
  done
  printf '%s' "$flow_record_kind"
)

# record_pair_kind <pair>: state or record, the pair's kind; refuses, exit 2, a pair with no = and
# attempts that is not a whole number.
record_pair_kind() (
  flow_record_key="${1%%=*}"
  [ "$flow_record_key" != "$1" ] || die "expected key=value, got $1" "$EXIT_USAGE"
  case "$1" in attempts=*[!0123456789]*) die "attempts takes a whole number, not ${1#attempts=}" "$EXIT_USAGE" ;; esac
  case "$flow_record_key" in *.*|*:) printf record ;; *) printf state ;; esac
)

# record_ensured_dir: the state dir, created when missing; refuses, exit 2, a state.dir that
# cannot be created or written.
record_ensured_dir() (
  flow_record_dir="$(state_dir)"
  { { [ -d "$flow_record_dir" ] || mkdir -p "$flow_record_dir" 2>/dev/null; } && [ -w "$flow_record_dir" ]; } \
    || die "state.dir $flow_record_dir cannot be created or written" "$EXIT_USAGE"
  printf '%s' "$flow_record_dir"
)

# record_seeded <set|take> <item> <state dir> <flow home> [<option>...]: one _state.py write. An
# item with no record yet sends the tracker's read along as the seed; a read that fails seeds nothing.
record_seeded() {
  flow_record_command="$1"; flow_record_item="$2"; flow_record_dir="$3"; flow_record_home="$4"; shift 4
  flow_record_seed=stdin
  [ ! -f "$flow_record_dir/$(item_slug "$flow_record_item").json" ] || flow_record_seed=none
  { [ "$flow_record_seed" = none ] || ( adapter read "$flow_record_item" ) </dev/null 2>/dev/null; } \
    | state_python "$flow_record_command" "$flow_record_dir" "$flow_record_home" "$flow_record_item" \
      --now "$(now_iso)" --machine "$(flow_machine)" --host "$(host_name)" --seed "$flow_record_seed" "$@"
}

# record_claim_file <item> <pair>...: the item's claim file, when a pair can name its step (step=,
# run.step= or any run:= value, whose JSON _state.py reads); nothing otherwise.
record_claim_file() (
  flow_record_item="$1"; shift
  for flow_record_pair in "$@"; do
    case "$flow_record_pair" in step=*|run.step=*|run:=*) item_claim_file "$flow_record_item"; exit 0 ;; esac
  done
)

# item_claim_file <item>: the claim.json of the item's pool worktree; nothing when it holds none.
item_claim_file() (
  flow_record_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$1" </dev/null 2>/dev/null)"
  [ -z "$flow_record_worktree" ] || [ ! -f "$(claim_file "$flow_record_worktree")" ] \
    || claim_file "$flow_record_worktree"
)
