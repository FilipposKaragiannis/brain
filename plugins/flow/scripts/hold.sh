#!/bin/sh
# Holds: an item whose plan changes the same existing behavior as another open item's waits
# behind it (state.held_by, state.held_reason). Only the plan step decides one, by the rule in
# skills/plan/holds.md; the ready filter keeps a held item back while its holder is open.
#   hold.sh candidates <item> [--touches a,b] [--json]
#                              the other open items that hold a claim (a pool claim or a run in
#                              flight) whose changes, or touches when they have no changes, share
#                              a path prefix with the item's touches (--touches replaces them):
#                              one markdown line each, with the title, the globs and the plan
#                              report when there is one; --json prints an array. Nothing when no
#                              item overlaps, or the item has no touches yet. An item held behind
#                              this one is left out, so two items never wait on each other
#   hold.sh set <item> <holder> <reason>
#                              hold the item behind <holder>: held_by, held_reason and a `held`
#                              line in events.log. A holder that is the item itself, closed or
#                              unreadable is refused, exit 1, with nothing written
#   hold.sh clear <item> <why> lift the hold: held_by and held_reason cleared and an `unheld`
#                              line with <why>; nothing when the item is not held
# Exit codes: 0 done · 1 refused · 2 bad usage.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
main="$(dirname "$home")"

# event <item> <kind> <text>: one events.log line, the text on one line.
event() { mkdir -p "$home"; printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$1" "$2" "$(printf '%s' "$3" | tr '\n\t' '  ')" >> "$home/events.log"; }

# claimed: "<item>\t<worktree>" for every item a pool worktree claims (not a reservation) or a run
# record names, once each.
claimed() {
  {
    cfg pool | while read -r p; do
      [ -n "$p" ] || continue
      case "$p" in /*) ;; *) p="$main/$p" ;; esac
      [ -f "$p/.flow/claim.json" ] || continue
      c="$(cat "$p/.flow/claim.json")"
      it="$(json_get "$c" item)"; [ -n "$it" ] || continue
      [ -z "$(json_get "$c" reserved)" ] || continue
      printf '%s\t%s\n' "$it" "$(cd "$p" && pwd)"
    done
    for f in "$home"/runs/*.json; do
      [ -f "$f" ] || continue
      r="$(cat "$f")"; it="$(json_get "$r" item)"; [ -n "$it" ] || continue
      printf '%s\t%s\n' "$it" "$(json_get "$r" worktree)"
    done
  } | awk -F '\t' '!seen[$1]++'
}

cmd_candidates() {
  item="$1"; shift; mine=""; as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --touches) [ $# -ge 2 ] || die "--touches takes globs, comma-separated" 2; mine="$(printf '%s' "$2" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep .)"; shift 2 ;;
      --json) as_json=1; shift ;;
      *) die "unknown option $1" 2 ;;
    esac
  done
  if [ -z "$mine" ]; then
    data="$(adapter read "$item")" || die "cannot read $item"
    mine="$(json_list "$data" state.touches)"
  fi
  rows=""
  if [ -n "$mine" ]; then
    rows="$(claimed | while IFS="$(printf '\t')" read -r other wt; do
      [ "$other" != "$item" ] || continue
      od="$(adapter read "$other" 2>/dev/null </dev/null)" || continue
      [ "$(json_get "$od" status)" = open ] || continue
      [ "$(state_get "$od" held_by)" != "$item" ] || continue
      kind=changes; globs="$(json_list "$od" state.changes)"
      [ -n "$globs" ] || { kind=touches; globs="$(json_list "$od" state.touches)"; }
      [ -n "$globs" ] && touches_overlap "$mine" "$globs" || continue
      plan=""
      for root in "$wt" "$main"; do
        f="$root/.flow/reports/$(item_slug "$other")/plan.md"
        [ -n "$root" ] && [ -f "$f" ] && { plan="$f"; break; }
      done
      json_obj "id=$other" "title=$(json_get "$od" title)" "by=$kind" \
        "globs:=$(printf '%s\n' "$globs" | python3 -I -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')" \
        "plan=$plan" "step=$(state_get "$od" step)"
      echo
    done)"
  fi
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$rows" | python3 -I -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))'
    return 0
  fi
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | python3 -I -c '
import json, sys
for line in sys.stdin:
    if not line.strip(): continue
    c = json.loads(line)
    what = "changes" if c["by"] == "changes" else "touches (no changes recorded)"
    out = "- %s \"%s\" (step %s): %s %s" % (c["id"], c["title"], c["step"] or "-", what, ", ".join("`%s`" % g for g in c["globs"]))
    out += "; plan: `%s`" % c["plan"] if c["plan"] else "; no plan report"
    print(out)'
}

cmd_set() {
  item="$1"; holder="$2"; reason="$(printf '%s' "$3" | tr '\n\t' '  ')"
  [ -n "$holder" ] || die "a hold names the item it waits behind" 2
  [ "$holder" != "$item" ] && hd="$(adapter read "$holder" 2>/dev/null)" && [ "$(json_get "$hd" status)" = open ] \
    || { echo "flow: $item is not held behind $holder: it is the item itself, closed or unreadable" >&2; exit 1; }
  adapter write-state "$item" "held_by=$holder" "held_reason=$reason" >/dev/null || die "could not write the hold on $item"
  event "$item" held "behind $holder: ${reason:-no reason given}"
}

cmd_clear() {
  item="$1"; why="$2"
  data="$(adapter read "$item")" || die "cannot read $item"
  [ -n "$(state_get "$data" held_by)" ] || return 0
  adapter write-state "$item" held_by= held_reason= >/dev/null || die "could not clear the hold on $item"
  event "$item" unheld "$why"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  candidates) [ $# -ge 1 ] || die "usage: hold.sh candidates <item> [--touches a,b] [--json]" 2; cmd_candidates "$@" ;;
  set) [ $# -eq 3 ] || die "usage: hold.sh set <item> <holder> <reason>" 2; cmd_set "$@" ;;
  clear) [ $# -eq 2 ] || die "usage: hold.sh clear <item> <why>" 2; cmd_clear "$@" ;;
  *) die "usage: hold.sh candidates|set|clear (see the header)" 2 ;;
esac
