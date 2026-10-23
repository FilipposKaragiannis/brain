#!/bin/sh
# notify.sh <gate> <item> <message>: one notification per human gate, on both hosts and from any
# shell. Desktop (osascript on macOS, notify-send elsewhere) unless notify.desktop is false; Slack
# through the incoming webhook in the FLOW_SLACK_WEBHOOK environment variable (so the URL stays out
# of the repository), else notify.slack_webhook in the config; and always a record in
# <flow home>/gates/<item>.json plus a line in <flow home>/events.log, which the board reads.
# The events: idle (the next job found nothing ready; notify.idle) and health (the health job found
# something: a gate waiting past its reminder, a diverged branch, a full pool; notify.health, on
# unless set to false) and review-stalled (a reviewer stayed silent through every chase). A gate names the item by its
# id and title and Slack links it to the tracker. The Slack message is a list (scripts/_slack.py): numbered questions
# stay numbered, long prose breaks into one bullet per sentence, ids and code names read as code.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
if [ "${1:-}" = "--event" ]; then
  # notify.sh --event <name> [--no-log] <message>: the same channels for something that is not a
  # gate (the queue ran dry). A line in events.log, unless the caller logged it, no gate record.
  [ $# -ge 3 ] || die "usage: notify.sh --event <name> [--no-log] <message>" 2
  name="$2"; shift 2; logged=1
  [ "$1" != "--no-log" ] || { logged=0; shift; }
  message="$1"
  mkdir -p "$home"
  [ "$logged" -eq 0 ] || printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "-" "$name" "$(printf '%s' "$message" | tr '\n' ' ')" >> "$home/events.log"
  title="flow: $name"; subtitle=""; link=""
else
  [ $# -ge 3 ] || die "usage: notify.sh <gate> <item> <message> | --event <name> <message>" 2
  gate="$1"; item="$2"; message="$3"
  mkdir -p "$home/gates"
  json_obj "gate=$gate" "item=$item" "message=$message" "time=$(now_iso)" "host=$(host_name)" > "$home/gates/$(item_slug "$item").json"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$item" "$gate" "$(printf '%s' "$message" | tr '\n' ' ')" >> "$home/events.log"
  title="flow: $gate on $item"
  read_item="$(adapter read "$item" 2>/dev/null)" || read_item=""
  subtitle="$([ -n "$read_item" ] && json_get "$read_item" title)"; url="$([ -n "$read_item" ] && json_get "$read_item" url)"
  link="$item${subtitle:+ $subtitle}"
fi
if [ "$(cfg notify.desktop)" != "false" ]; then
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$(printf '%s' "$message" | head -c 200 | tr '"' "'")\" with title \"$title\" subtitle \"$(printf '%s' "$subtitle" | tr '"' "'")\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$(printf '%s' "$message" | head -c 200)" >/dev/null 2>&1 || true
  fi
fi
hook="${FLOW_SLACK_WEBHOOK:-$(cfg notify.slack_webhook)}"
if [ -n "$hook" ] && command -v curl >/dev/null 2>&1; then
  payload="$(python3 -I "$FLOW_PLUGIN/scripts/_slack.py" "$title" "$link" "${url:-}" "${gate:-}" "${item:-}" "$message")"
  curl -s -S -m 10 -X POST -H 'Content-type: application/json' --data "$payload" "$hook" >/dev/null 2>&1 || echo "flow: Slack notification failed" >&2
fi
echo "notified: $title"
