#!/bin/sh
# notify.sh <gate> <item> <message>: one notification per human gate, on both hosts and from any
# shell. Desktop (osascript on macOS, notify-send elsewhere) unless notify.desktop is false; Slack
# through the incoming webhook in the FLOW_SLACK_WEBHOOK environment variable (so the URL stays out
# of the repository), else notify.slack_webhook in the config; and always a record in
# <flow home>/gates/<item>.json plus a line in <flow home>/events.log, which the board reads.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
if [ "${1:-}" = "--event" ]; then
  # notify.sh --event <name> <message>: the same channels for something that is not a gate (the
  # queue ran dry). A line in events.log, no gate record.
  [ $# -ge 3 ] || die "usage: notify.sh --event <name> <message>" 2
  name="$2"; message="$3"
  mkdir -p "$home"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "-" "$name" "$(printf '%s' "$message" | tr '\n' ' ')" >> "$home/events.log"
  title="flow: $name"
else
  [ $# -ge 3 ] || die "usage: notify.sh <gate> <item> <message> | --event <name> <message>" 2
  gate="$1"; item="$2"; message="$3"
  mkdir -p "$home/gates"
  json_obj "gate=$gate" "item=$item" "message=$message" "time=$(now_iso)" "host=$(host_name)" > "$home/gates/$(item_slug "$item").json"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$item" "$gate" "$(printf '%s' "$message" | tr '\n' ' ')" >> "$home/events.log"
  title="flow: $gate on $item"
fi
if [ "$(cfg notify.desktop)" != "false" ]; then
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$(printf '%s' "$message" | head -c 200 | tr '"' "'")\" with title \"$title\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$(printf '%s' "$message" | head -c 200)" >/dev/null 2>&1 || true
  fi
fi
hook="${FLOW_SLACK_WEBHOOK:-$(cfg notify.slack_webhook)}"
if [ -n "$hook" ] && command -v curl >/dev/null 2>&1; then
  payload="$(json_obj "text=*$title*
$message")"
  curl -s -S -m 10 -X POST -H 'Content-type: application/json' --data "$payload" "$hook" >/dev/null 2>&1 || echo "flow: Slack notification failed" >&2
fi
echo "notified: $title"
