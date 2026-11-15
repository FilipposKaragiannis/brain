#!/bin/sh
# JSON helpers shared by every plugin script. POSIX sh. Uses jq when present, else python3.
# Source: shared/sh/json.sh. tools/generate.sh copies it into each plugin; do not edit the copies.

json_get() {
  # $1 JSON text, $2 dotted path (numbers index arrays). Prints a string raw, anything else as JSON.
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg p "$2" '
      getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) // empty
      | if type == "string" then . else tojson end' 2>/dev/null
  else
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v[int(k)] if k.isdigit() else v[k]
except Exception:
    sys.exit(0)
if v is None or v is False:
    sys.exit(0)
print(v if isinstance(v, str) else json.dumps(v))' "$2" 2>/dev/null
  fi
}

json_list() {
  # $1 JSON text, $2 dotted path to an array of strings. One element per line.
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg p "$2" '
      getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end)) // [] | .[]
      | if type == "string" then . else tojson end' 2>/dev/null
  else
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v[int(k)] if k.isdigit() else v[k]
except Exception:
    sys.exit(0)
for e in v or []:
    print(e if isinstance(e, str) else json.dumps(e))' "$2" 2>/dev/null
  fi
}

json_length() {
  # $1 JSON text, $2 dotted path to an array. Prints its length, 0 when absent.
  n="$(json_list "$1" "$2" | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

json_string() {
  # $1 text. Prints it as a JSON string literal; bytes that are not UTF-8 become U+FFFD.
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.buffer.read().decode("utf-8", "replace")))'
  fi
}
