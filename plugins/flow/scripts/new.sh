#!/bin/sh
# New item: new.sh <kind> <title> [--size S|M|L] [--type NAME] [--area NAME] [--priority NAME] [--blocked-by id,id] [--parent id] [--body TEXT | --body-file FILE]
# Picks the tracker from the config (adapters.<kind>, else adapters.default) and prints the new
# id. kind is epic, task or bug. --body-file - reads the body from stdin. The agents' one entry
# for creating work: a session that picks items from a backlog creates the follow-ups here.
# --type names the tracker's issue type (Feature, Chore) where the adapter has types; --area the
# item's area (github.fields.area on GitHub, an area field on a local item); --priority its
# priority (github.fields.priority on GitHub, a priority field on a local item).
# A child (--parent) takes the parent's priority and area unless it names its own, so a split
# item's children are ready as soon as the parent would be. A child left without a priority that
# github.ready_needs asks for is said on stderr: it is never ready until one is set.
. "$(dirname "$0")/../lib/flow.sh"
usage="usage: new <epic|task|bug> <title> [--size S|M|L] [--type NAME] [--area NAME] [--priority NAME] [--blocked-by a,b] [--parent id] [--body TEXT | --body-file FILE]"
[ $# -ge 2 ] || die "$usage" 2
kind="$1"; title="$2"; shift 2
case "$kind" in epic|task|bug) ;; *) die "kind must be epic, task or bug, not $kind" 2 ;; esac
[ -n "$title" ] || die "the title is empty" 2
[ -f "$(config_file)" ] || die "no .flow/config.yaml in this repository; run flow:init first" 2
body=""; args=""; area=""; priority=""; parent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body) body="$2"; shift 2 ;;
    --body-file) if [ "$2" = - ]; then body="$(cat)"; else body="$(cat "$2")" || die "cannot read $2" 2; fi; shift 2 ;;
    --size|--type|--blocked-by) args="$args $1 $2"; shift 2 ;;
    --parent) parent="$2"; args="$args $1 $2"; shift 2 ;;
    --area) area="$2"; shift 2 ;;
    --priority) priority="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
inherited=""
if [ -n "$parent" ] && { [ -z "$priority" ] || [ -z "$area" ]; }; then
  pdata="$(adapter read "$parent" 2>/dev/null)" || die "cannot read the parent $parent" 2
  [ -n "$priority" ] || { priority="$(json_get "$pdata" priority)"; [ -z "$priority" ] || inherited="$inherited priority $priority"; }
  [ -n "$area" ] || { area="$(json_get "$pdata" area)"; [ -z "$area" ] || inherited="$inherited, area $area"; }
fi
name="$(adapter_for_kind "$kind")"
set --
[ -z "$area" ] || set -- "$@" --area "$area"
[ -z "$priority" ] || set -- "$@" --priority "$priority"
# shellcheck disable=SC2086
id="$(adapter create "$name" "$kind" "$title" $args "$@" --body "$body")" || exit $?
printf '%s\n' "$id"
[ -z "$inherited" ] || echo "flow: $id takes${inherited#,} from its parent $parent" >&2
if [ -z "$priority" ] && [ "$name" = github ] && cfg github.ready_needs | grep -qx priority; then
  echo "flow: $id has no priority and github.ready_needs asks for one, so it is not ready until one is set" >&2
fi
