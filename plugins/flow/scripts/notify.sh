#!/bin/sh
# notify.sh <gate> <item> <message>: one notification per human gate, on both hosts and from any
# shell. Desktop (osascript on macOS, notify-send elsewhere) unless notify.desktop is false; Slack
# through the incoming webhook in the FLOW_SLACK_WEBHOOK environment variable (so the URL stays out
# of the repository), else notify.slack_webhook in the config; and always a record in
# <flow home>/gates/<item>.json plus a line in <flow home>/events.log, which the board reads.
# A gate names the item by its id and title, Slack links it to the tracker, and the message keeps
# its lines, so numbered questions read as a list.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
if [ "${1:-}" = "--event" ]; then
  # notify.sh --event <name> <message>: the same channels for something that is not a gate (the
  # queue ran dry). A line in events.log, no gate record.
  [ $# -ge 3 ] || die "usage: notify.sh --event <name> <message>" 2
  name="$2"; message="$3"
  mkdir -p "$home"
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "-" "$name" "$(printf '%s' "$message" | tr '\n' ' ')" >> "$home/events.log"
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
  payload="$(python3 -I -c '
import json, sys
esc = lambda s: s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
title, link, url, gate, item, message = sys.argv[1:7]
if gate:
    head = "*flow: %s* on %s" % (esc(gate), "<%s|%s>" % (url, esc(link)) if url else "*%s*" % esc(link))
    tail = ("\nAnswer on the issue: comment `/answer <your answer>`, or `/answer` alone for the recommendations."
            if url and item.startswith("gh#") else "\nAnswer in a session: `flow:gate %s \"<your answer>\"`" % item)
else:
    head, tail = "*%s*" % esc(title), ""
print(json.dumps({"text": "%s\n%s%s" % (head, esc(message), tail)}))' "$title" "$link" "${url:-}" "${gate:-}" "${item:-}" "$message")"
  curl -s -S -m 10 -X POST -H 'Content-type: application/json' --data "$payload" "$hook" >/dev/null 2>&1 || echo "flow: Slack notification failed" >&2
fi
echo "notified: $title"
