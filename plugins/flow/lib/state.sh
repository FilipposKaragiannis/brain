#!/bin/sh
# The flow record of an item: one JSON file per item under state.dir that holds its workflow
# state, opened only by scripts/_state.py. Sourced by lib/flow.sh; defines functions and runs
# nothing. No public function changes a variable of its caller or reads its stdin, and each returns
# its code rather than exiting the caller.
#   state_dir                   state.dir: absolute as given, relative under the main worktree;
#                               unset, <flow home>/state
#   record_file <item>          <state dir>/<slug>.json; closed/<slug>.json once archived
#   tracker_state               tracker_state: labels (the default) or none; another value is
#                               refused, exit 2
#   flow_machine                this machine's name: FLOW_MACHINE, else hostname -s
#   record_get <item> <key>     one of the twenty state keys through the key map (gate reads none
#                               when clear), or a record path (gate.options.0.label, claim.machine);
#                               a string raw, anything else as JSON, nothing with no record
#   record_show <item>          the record as JSON; exit 1 with none
#   record_set <item> <pair>... key=value for the twenty keys (adapters/README.md; a dash reads as
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
#   take_item <item>            this machine holds the item: claim.machine, claim.host and
#                               claim.claimed_at, when the claim names no machine yet
#   record_archive <item>       the record to closed/; nothing with no record; exit 1 when
#                               another machine holds it
# With no record yet, record_set and take_item start one from the tracker's state (lazy seed).
# record_get, record_show, record_set, take_item and record_archive refuse, exit 2, an id that is
# not of its adapter's shape (item_id_shaped).

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
  case "${flow_record_tracker_state:-labels}" in
    labels|none) printf '%s' "${flow_record_tracker_state:-labels}" ;;
    *) die "tracker_state in .flow/config.yaml is labels or none, not $flow_record_tracker_state" "$EXIT_USAGE" ;;
  esac
)

flow_machine() { printf '%s' "${FLOW_MACHINE:-$(hostname -s)}"; }

record_get() (
  [ $# -eq 2 ] || die "usage: record_get <item> <key>" "$EXIT_USAGE"
  item_shape_required "$1"
  FLOW_HOME="$(flow_home)"
  state_python get "$(state_dir)" "$FLOW_HOME" "$1" -- "$2"
)

record_show() (
  [ $# -eq 1 ] || die "usage: record_show <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  FLOW_HOME="$(flow_home)"
  state_python show "$(state_dir)" "$FLOW_HOME" "$1"
)

record_set() (
  [ $# -ge 2 ] || die "usage: record_set <item> <key=value>..." "$EXIT_USAGE"
  item_shape_required "$1"
  flow_record_item="$1"; shift
  flow_record_kind="$(record_pairs_kind "$@")" || exit "$EXIT_USAGE"
  FLOW_HOME="$(flow_home)"
  flow_record_dir="$(record_ensured_dir)" || exit "$EXIT_USAGE"
  flow_record_tracker="$(tracker_state)" || exit "$EXIT_USAGE"
  if [ "$flow_record_tracker" = labels ] && [ "$flow_record_kind" = state ]; then
    tracker_mirror "$flow_record_item" "$@" || exit
  fi
  record_seeded set "$flow_record_item" "$flow_record_dir" "$FLOW_HOME" \
    --claim-file "$(record_claim_file "$flow_record_item" "$@")" -- "$@"
)

take_item() (
  [ $# -eq 1 ] || die "usage: take_item <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  FLOW_HOME="$(flow_home)"
  flow_record_dir="$(record_ensured_dir)" || exit "$EXIT_USAGE"
  record_seeded take "$1" "$flow_record_dir" "$FLOW_HOME"
)

record_archive() (
  [ $# -eq 1 ] || die "usage: record_archive <item>" "$EXIT_USAGE"
  item_shape_required "$1"
  FLOW_HOME="$(flow_home)"
  state_python archive "$(state_dir)" "$FLOW_HOME" "$1" --machine "$(flow_machine)"
)

# item_shape_required <item>: refuses, exit 2, an id that is not of its adapter's shape.
item_shape_required() {
  item_id_shaped "$1" || die "$1 is no item id of an adapter's shape, so it has no record" "$EXIT_USAGE"
}

# state_python <command> <state dir> <flow home> <item> [<option>...]: one _state.py call on the
# item's record.
state_python() {
  flow_record_python_command="$1"; flow_record_python_dir="$2"; flow_record_python_home="$3"
  flow_record_python_item="$4"; shift 4
  python3 -I "$FLOW_PLUGIN/scripts/_state.py" "$flow_record_python_command" \
    --state-dir "$flow_record_python_dir" --flow-home "$flow_record_python_home" \
    --item "$flow_record_python_item" "$@"
}

# tracker_mirror <item> <pair>...: the one adapter write-state call of the flow.
tracker_mirror() ( adapter write-state "$@" ) </dev/null >&2

# record_pairs_kind <pair>...: state or record, the kind every pair is; refuses, exit 2, a pair
# with no =, the two kinds together and attempts that is not a whole number.
record_pairs_kind() (
  flow_record_kind=""
  for flow_record_pair in "$@"; do
    flow_record_key="${flow_record_pair%%=*}"
    [ "$flow_record_key" != "$flow_record_pair" ] || die "expected key=value, got $flow_record_pair" "$EXIT_USAGE"
    case "$flow_record_pair" in attempts=*[!0123456789]*) die "attempts takes a whole number, not ${flow_record_pair#attempts=}" "$EXIT_USAGE" ;; esac
    case "$flow_record_key" in *.*|*:) flow_record_pair_kind=record ;; *) flow_record_pair_kind=state ;; esac
    [ "${flow_record_kind:-$flow_record_pair_kind}" = "$flow_record_pair_kind" ] \
      || die "a write holds state pairs or record pairs, never both: $*" "$EXIT_USAGE"
    flow_record_kind="$flow_record_pair_kind"
  done
  printf '%s' "$flow_record_kind"
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

# record_claim_file <item> <pair>...: the claim.json of the item's pool worktree, when a pair
# names its step (step=, run.step= or a run); nothing otherwise.
record_claim_file() (
  flow_record_item="$1"; shift
  for flow_record_pair in "$@"; do
    case "$flow_record_pair" in step=*|run.step=*|run:=\{*) ;; *) continue ;; esac
    flow_record_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$flow_record_item" </dev/null 2>/dev/null)"
    [ -n "$flow_record_worktree" ] && [ -f "$flow_record_worktree/.flow/claim.json" ] \
      && printf '%s/.flow/claim.json' "$flow_record_worktree"
    exit 0
  done
)
