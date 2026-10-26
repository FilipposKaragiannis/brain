#!/bin/sh
# Shared helpers for the flow plugin. POSIX sh. Sourced by the adapters, the scripts and the hooks.
# Paths: the plugin root is two levels up from any script under adapters/<name>/ or scripts/, one
# level up from hooks/. Callers set FLOW_PLUGIN before sourcing when they know better.
if [ -z "${FLOW_PLUGIN:-}" ]; then
  _flow_here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -f "$_flow_here/../lib/flow.sh" ]; then FLOW_PLUGIN="$(cd "$_flow_here/.." && pwd)"
  else FLOW_PLUGIN="$(cd "$_flow_here/../.." && pwd)"; fi
fi
export FLOW_PLUGIN
. "$FLOW_PLUGIN/lib/json.sh"
. "$FLOW_PLUGIN/lib/stamp.sh"

# macOS ships /usr/bin/git as an xcrun shim that fails in sandboxes that block its cache file
# ("Failed to locate 'git'"). When the shim is broken and Xcode's git exists, use that one.
if ! command git --version >/dev/null 2>&1 && [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/git ]; then
  git() { /Applications/Xcode.app/Contents/Developer/usr/bin/git "$@"; }
fi

die() { echo "flow: $1" >&2; exit "${2:-1}"; }

# gh: the GitHub CLI, called again when it fails with a 5xx answer or a dropped connection, up
# to three times, after the waits in FLOW_GH_RETRY_WAIT (seconds, default "2 5"). GitHub's API
# has such minutes most days and one of them should not end a run or lose a write. A body the
# call reads from stdin (a `-` or `@-` argument) is kept in a file first, so every try sends it.
# Any other failure is final at once. _call.py does the same for the adapter's Python.
gh() {
  _gh_in=""
  for _gh_a in "$@"; do
    case "$_gh_a" in -|*=@-) _gh_in="$(mktemp "${TMPDIR:-/tmp}/flow-gh.XXXXXX")" && cat > "$_gh_in"; break ;; esac
  done
  _gh_err="$(mktemp "${TMPDIR:-/tmp}/flow-gh.XXXXXX")" || _gh_err=/dev/null
  for _gh_wait in ${FLOW_GH_RETRY_WAIT:-2 5} end; do
    if [ -n "$_gh_in" ]; then command gh "$@" < "$_gh_in" 2> "$_gh_err"; else command gh "$@" 2> "$_gh_err"; fi
    _gh_code=$?
    [ "$_gh_code" -ne 0 ] && [ "$_gh_wait" != end ] && gh_blip "$_gh_err" || break
    echo "flow: gh: $(head -n 1 "$_gh_err"); trying again in ${_gh_wait}s" >&2
    sleep "$_gh_wait"
  done
  [ "$_gh_err" = /dev/null ] || { cat "$_gh_err" >&2; rm -f "$_gh_err"; }
  [ -z "$_gh_in" ] || rm -f "$_gh_in"
  return "$_gh_code"
}
# gh_blip <stderr file>: true when gh's error is GitHub's or the network's, not the call's.
gh_blip() { grep -Eqi 'HTTP 5[0-9][0-9]|connection reset|error connecting|timeout|unexpected EOF|temporarily unavailable' "$1"; }

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

# The install set of plugin <root>: every file whose content init copies into a project, plus
# init.sh (it shapes the wrappers). Not the manifest: a version bump alone changes no installed
# file. init stamps its hash; the session-start hook compares.
flow_install_set() {
  for f in "$1"/skills/init/scripts/init.sh "$1"/templates/* \
           "$1"/codex-agents/*.toml; do [ -f "$f" ] && echo "$f"; done | sort
}
flow_source_hash() { hash_files $(flow_install_set "$1"); }

main_worktree() { git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'; }

# The flow home holds the project config, the local items and the gate records. It is the main
# worktree's .flow, found from any linked worktree. FLOW_HOME overrides it (tests).
flow_home() {
  if [ -n "${FLOW_HOME:-}" ]; then printf '%s' "$FLOW_HOME"; return; fi
  main="$(main_worktree)"
  [ -n "$main" ] || main="$(pwd)"
  printf '%s/.flow' "$main"
}

# claude_hooks_present [root]: the project's Claude settings name both flow worktree hooks. A plugin
# cannot provide them (the worktree is created before plugins load), so init prints the entry
# and the install check and the session-start hook report it missing.
claude_hooks_present() {
  _r="${1:-.}"; _f="$(cat "$_r/.claude/settings.json" "$_r/.claude/settings.local.json" 2>/dev/null)"
  printf '%s' "$_f" | grep -q 'worktree-create.sh' && printf '%s' "$_f" | grep -q 'worktree-remove.sh'
}

config_file() { printf '%s/config.yaml' "$(flow_home)"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

host_name() {
  if [ -n "${CODEX_THREAD_ID:-}${CODEX_SANDBOX:-}" ]; then printf 'codex'
  elif [ -n "${CLAUDECODE:-}" ]; then printf 'claude'
  else printf 'shell'; fi
}

# yaml_get <file> <dotted.path>: a flat YAML subset. Two-space indentation, `key: value`, nested
# maps, block lists (`- item`) and inline lists (`[a, b]`). Quotes are stripped. A list prints one
# item per line. Anchors, multi-line scalars and flow maps are not supported on purpose: the
# config file stays simple enough for every shell.
yaml_get() {
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    function strip(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    function emit_inline(s,   n, parts, i) {
      s = strip(s); sub(/^\[/, "", s); sub(/\]$/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) { p = strip(parts[i]); if (p != "") print p }
    }
    BEGIN { n = split(want, keys, "."); depth = 0; found = 0 }
    /^[ \t]*(#|$)/ { next }
    {
      line = $0
      match(line, /^ */); indent = RLENGTH / 2
      body = substr(line, RLENGTH + 1)
      sub(/[ \t]+#.*$/, "", body)
      if (found) {
        if (indent < depth) exit
        if (body ~ /^- /) { print strip(substr(body, 3)); next }
        if (indent == depth && body ~ /^-$/) next
        exit
      }
      if (indent != depth) { if (indent < depth) exit; next }
      if (body ~ /^- /) next
      key = body; sub(/:.*$/, "", key); key = strip(key)
      val = body; if (index(val, ":") == 0) next
      val = substr(val, index(val, ":") + 1); val = strip(val)
      if (key != keys[depth + 1]) next
      if (depth + 1 == n) {
        if (val ~ /^\[/) { emit_inline(val); exit }
        if (val != "") { print val; exit }
        found = 1; depth = indent + 1; next
      }
      depth = indent + 1
    }' "$1"
}

cfg() { yaml_get "$(config_file)" "$1"; }

# flow_lock <name>: one holder at a time across sessions and unattended runs: a directory
# <flow home>/<name>.lock with the holder's pid. Waits up to FLOW_LOCK_WAIT seconds (default 60),
# then returns 1. A lock whose pid is gone is stale and taken over. flow_unlock releases it; so
# does the holder's exit.
flow_lock() {
  _flow_lock="$(flow_home)/$1.lock"; _waited=0
  mkdir -p "$(flow_home)"
  while ! mkdir "$_flow_lock" 2>/dev/null; do
    _pid="$(cat "$_flow_lock/pid" 2>/dev/null)"
    if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then rm -rf "$_flow_lock"; continue; fi
    [ "$_waited" -ge "${FLOW_LOCK_WAIT:-60}" ] && { _flow_lock=""; return 1; }
    sleep 1; _waited=$((_waited + 1))
  done
  echo $$ > "$_flow_lock/pid"
  trap 'flow_unlock' EXIT
  trap 'flow_unlock; exit 130' INT TERM
}
flow_unlock() {
  [ -n "${_flow_lock:-}" ] && rm -rf "$_flow_lock"
  _flow_lock=""
}

# cfg_or <path> <default>
cfg_or() { v="$(cfg "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

# item_slug gh#310 -> gh-310 ; local:bug/12 -> local-bug-12. Safe as a directory and branch name.
item_slug() { printf '%s' "$1" | tr ':/#' '---'; }

# adapter_for <id>: the adapter that owns an item, from the id prefix.
adapter_for() {
  case "$1" in
    gh#*) printf 'github' ;;
    local:*) printf 'local' ;;
    *) return 1 ;;
  esac
}

# adapter_for_kind <kind>: the adapter that new items of a kind go to, from the config.
adapter_for_kind() { v="$(cfg "adapters.$1")"; [ -n "$v" ] && printf '%s' "$v" || cfg_or "adapters.default" "local"; }

# adapters_configured: every adapter named in the config, local always, one per line.
adapters_configured() {
  { echo local; cfg "adapters.default"; for k in epic task bug; do cfg "adapters.$k"; done; } | grep -v '^$' | sort -u
}

# adapter <op> <id|adapter-name> [args...]: run one adapter operation. The first argument after
# the op is an item id (adapter from its prefix) or an adapter name (for list and list-ready).
adapter() {
  op="$1"; who="$2"; shift 2
  name="$(adapter_for "$who" 2>/dev/null)" || name="$who"
  script="$FLOW_PLUGIN/adapters/$name/$op.sh"
  [ -x "$script" ] || die "no adapter operation $name/$op"
  if [ "$name" = "$who" ]; then "$script" "$@"; else "$script" "$who" "$@"; fi
}

# state_get <item-json> <key>: one state field from an item read.
state_get() { json_get "$1" "state.$2"; }

# Reports for an item live in the repository the step runs in: the claimed worktree for work
# steps, the main worktree for planning steps. reports_dir <item> [root].
reports_dir() {
  root="${2:-$(repo_root)}"
  [ -n "$root" ] || root="$(pwd)"
  printf '%s/.flow/reports/%s' "$root" "$(item_slug "$1")"
}

claim_file() { printf '%s/.flow/claim.json' "${1:-$(repo_root)}"; }

# profile_select <kind> <size>: the profile from profiles.json; the caller applies overrides.
profile_select() {
  profiles="$(cat "$FLOW_PLUGIN/profiles.json")"
  v="$(json_get "$profiles" "select.$1")"
  case "$v" in
    "") json_get "$profiles" "select.task.${2:-M}" ;;
    \{*) json_get "$profiles" "select.$1.${2:-M}" ;;
    *) printf '%s' "$v" ;;
  esac
}

profile_steps() { json_list "$(cat "$FLOW_PLUGIN/profiles.json")" "profiles.$1"; }

step_field() { json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "steps.$1.$2"; }

# json_obj key=value key:=raw ... : a flat JSON object. key=value always writes a string, digits
# too (a title 0451 stays "0451"); key:=value writes the value as JSON as given (number, object,
# array, bool), so a number is key:=value and the caller makes sure it is one.
json_obj() {
  out="{"; sep=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      *:) k="${k%:}"; lit="$v" ;;
      *) lit="$(json_string "$v")" ;;
    esac
    out="$out$sep$(json_string "$k"):$lit"; sep=","
  done
  printf '%s}' "$out"
}

# yaml_keys <file> <dotted.path>: the child keys of a map, one per line (top level when the
# path is empty).
yaml_keys() {
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    BEGIN { n = (want == "") ? 0 : split(want, keys, "."); depth = 0; found = (n == 0) }
    /^[ \t]*(#|$)/ { next }
    {
      match($0, /^ */); indent = RLENGTH / 2
      body = substr($0, RLENGTH + 1); sub(/[ \t]+#.*$/, "", body)
      if (body ~ /^- /) next
      key = body; sub(/:.*$/, "", key); sub(/^[ \t]+/, "", key); sub(/[ \t]+$/, "", key)
      if (found) { if (indent < depth) exit; if (indent == depth && index(body, ":")) print key; next }
      if (indent != depth) { if (indent < depth) exit; next }
      if (key != keys[depth + 1]) next
      depth = indent + 1
      if (depth == n) found = 1
    }' "$1"
}

# yaml_line <file> <dotted.path>: the line number of the key, empty when it is absent. For
# messages that point the owner at the line to fix.
yaml_line() {
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    BEGIN { n = split(want, keys, "."); depth = 0 }
    /^[ \t]*(#|$)/ { next }
    {
      match($0, /^ */); indent = RLENGTH / 2
      body = substr($0, RLENGTH + 1); sub(/[ \t]+#.*$/, "", body)
      if (body ~ /^- /) next
      key = body; sub(/:.*$/, "", key); sub(/^[ \t]+/, "", key); sub(/[ \t]+$/, "", key)
      if (indent != depth) { if (indent < depth) exit; next }
      if (key != keys[depth + 1]) next
      depth = indent + 1
      if (depth == n) { print NR; exit }
    }' "$1"
}

# json_set <json> <key> <value-json>: set one top-level key. Needs jq or python3.
json_set() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -c --arg k "$2" --argjson v "$3" '.[$k] = $v'
  else
    printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin); d[sys.argv[1]] = json.loads(sys.argv[2]); print(json.dumps(d))' "$2" "$3"
  fi
}

# glob_match <glob> <path>: shell pattern match where ** matches across slashes.
glob_match() {
  pat="$(printf '%s' "$1" | sed 's|\*\*/|*|g; s|\*\*|*|g')"
  # shellcheck disable=SC2254
  case "$2" in $pat) return 0 ;; esac
  return 1
}

# touches_overlap "<globs a, one per line>" "<globs b, one per line>": true when any pair can
# name the same file. Two globs overlap when one matches the other's literal prefix.
touches_overlap() {
  printf '%s\n' "$1" | while read -r a; do
    [ -n "$a" ] || continue
    printf '%s\n' "$2" | while read -r b; do
      [ -n "$b" ] || continue
      pa="${a%%\**}"; pb="${b%%\**}"
      case "$pa" in "$pb"*) exit 3 ;; esac
      case "$pb" in "$pa"*) exit 3 ;; esac
    done
    [ $? -eq 3 ] && exit 3
  done
  [ $? -eq 3 ]
}

# agent_model <agent> / agent_effort <agent>: from the generated Claude agent file's frontmatter.
agent_model() { [ -n "$1" ] && [ -f "$FLOW_PLUGIN/agents/$1.md" ] && sed -n '/^---$/,/^---$/{s/^model: *//p;}' "$FLOW_PLUGIN/agents/$1.md" | head -1; }
agent_effort() { [ -n "$1" ] && [ -f "$FLOW_PLUGIN/agents/$1.md" ] && sed -n '/^---$/,/^---$/{s/^effort: *//p;}' "$FLOW_PLUGIN/agents/$1.md" | head -1; }
