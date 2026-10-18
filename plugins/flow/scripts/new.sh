#!/bin/sh
# New item: new.sh <kind> <title> [--size S|M|L] [--type NAME] [--area NAME] [--blocked-by id,id] [--parent id] [--body TEXT | --body-file FILE]
# Picks the tracker from the config (adapters.<kind>, else adapters.default) and prints the new
# id. kind is epic, task or bug. --body-file - reads the body from stdin. The agents' one entry
# for creating work: a session that picks items from a backlog creates the follow-ups here.
# --type names the tracker's issue type (Feature, Chore) where the adapter has types; --area the
# item's area (github.fields.area on GitHub, an area field on a local item).
. "$(dirname "$0")/../lib/flow.sh"
[ $# -ge 2 ] || die "usage: new <epic|task|bug> <title> [--size S|M|L] [--type NAME] [--area NAME] [--blocked-by a,b] [--parent id] [--body TEXT | --body-file FILE]" 2
kind="$1"; title="$2"; shift 2
case "$kind" in epic|task|bug) ;; *) die "kind must be epic, task or bug, not $kind" 2 ;; esac
[ -n "$title" ] || die "the title is empty" 2
[ -f "$(config_file)" ] || die "no .flow/config.yaml in this repository; run flow:init first" 2
body=""; set -- "$@"
args=""; area=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body) body="$2"; shift 2 ;;
    --body-file) if [ "$2" = - ]; then body="$(cat)"; else body="$(cat "$2")" || die "cannot read $2" 2; fi; shift 2 ;;
    --size|--type|--blocked-by|--parent) args="$args $1 $2"; shift 2 ;;
    --area) area="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
name="$(adapter_for_kind "$kind")"
# shellcheck disable=SC2086
if [ -n "$area" ]; then adapter create "$name" "$kind" "$title" $args --area "$area" --body "$body"
else adapter create "$name" "$kind" "$title" $args --body "$body"; fi
