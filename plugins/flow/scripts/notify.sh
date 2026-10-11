#!/bin/sh
# notify.sh <gate> <item> <message>: one notification per human gate, on both hosts and from any
# shell. Desktop (osascript on macOS, notify-send elsewhere) unless notify.desktop is false; Slack
# through the incoming webhook in notify.slack_webhook; and always a record in
# <flow home>/gates/<item>.json plus a line in <flow home>/events.log, which the board reads.
. "$(dirname "$0")/../lib/flow.sh"
[ $# -ge 3 ] || die "usage: notify.sh <gate> <item> <message>" 2
gate="$1"; item="$2"; message="$3"
home="$(flow_home)"
mkdir -p "$home/gates"
json_obj "gate=$gate" "item=$item" "message=$message" "time=$(now_iso)" "host=$(host_name)" > "$home/gates/$(item_slug "$item").json"
printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$item" "$gate" "$(printf '%s' "$message" | tr '\n' ' ')" >> "$home/events.log"
title="flow: $gate on $item"
if [ "$(cfg notify.desktop)" != "false" ]; then
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$(printf '%s' "$message" | head -c 200 | tr '"' "'")\" with title \"$title\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$(printf '%s' "$message" | head -c 200)" >/dev/null 2>&1 || true
  fi
fi
hook="$(cfg notify.slack_webhook)"
if [ -n "$hook" ] && command -v curl >/dev/null 2>&1; then
  payload="$(json_obj "text=*$title*
$message")"
  curl -s -S -m 10 -X POST -H 'Content-type: application/json' --data "$payload" "$hook" >/dev/null 2>&1 || echo "flow: Slack notification failed" >&2
fi
echo "notified: $title"
