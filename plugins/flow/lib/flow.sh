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
_flow_xcode_git=/Applications/Xcode.app/Contents/Developer/usr/bin/git
case "${FLOW_GIT_PROGRAM:-}" in
  git|"$_flow_xcode_git") [ "${FLOW_GIT_SEARCH_PATH:-}" = "$PATH" ] || FLOW_GIT_PROGRAM="" ;;
  *) FLOW_GIT_PROGRAM="" ;;
esac
if [ -z "$FLOW_GIT_PROGRAM" ]; then
  FLOW_GIT_PROGRAM=git
  if ! command git --version >/dev/null 2>&1 && [ -x "$_flow_xcode_git" ]; then FLOW_GIT_PROGRAM="$_flow_xcode_git"; fi
fi
FLOW_GIT_SEARCH_PATH="$PATH"
export FLOW_GIT_PROGRAM FLOW_GIT_SEARCH_PATH
[ "$FLOW_GIT_PROGRAM" = git ] || git() { "$_flow_xcode_git" "$@"; }

_flow_owner_only_umask=077
_flow_python_cache_folder=""
case "${XDG_CACHE_HOME:-}" in
  /*) _flow_python_cache_folder="$XDG_CACHE_HOME/flow/python" ;;
  *) case "${HOME:-}" in /*) _flow_python_cache_folder="$HOME/.cache/flow/python" ;; esac ;;
esac
if [ -n "$_flow_python_cache_folder" ]; then
  cached_python3() {
    [ -d "$_flow_python_cache_folder" ] || (umask "$_flow_owner_only_umask" && mkdir -p "$_flow_python_cache_folder") 2>/dev/null || true
    python3 -X "pycache_prefix=$_flow_python_cache_folder" "$@"
  }
else
  cached_python3() { python3 "$@"; }
fi

die() { echo "flow: $1" >&2; exit "${2:-1}"; }

# gh: the GitHub CLI, called again when it fails with a 5xx answer or a dropped connection, up
# to three tries, after the waits in FLOW_GH_RETRY_WAIT (seconds, default "2 5"). GitHub's API
# has such minutes most days and one of them should not end a run or lose a write. A body the
# call reads from stdin (a `-` or `@-` argument) is kept in a file first, so every try sends it.
# Only the last try's stdout reaches the caller: `gh api` prints the error body on a failure.
# Any other failure is final at once. _call.py does the same for the adapter's Python. A signal
# during a try leaves the try's files in TMPDIR; no caller's trap knows their names.
# gh_once: one try, for a call that creates something (an issue, a comment): a lost answer can
# follow a write that landed, and a second try would make a second one.
gh_once() { command gh "$@"; }
gh() {
  _gh_in=""
  for _gh_a in "$@"; do
    case "$_gh_a" in -|*=@-|--body-file=-|--input=-)
      _gh_in="$(mktemp "${TMPDIR:-/tmp}/flow-gh.XXXXXX")" || { command gh "$@"; return; }  # no room: one plain try
      cat > "$_gh_in" || { rm -f "$_gh_in"; echo "flow: gh: cannot keep the body for a second try" >&2; return 1; }
      break ;;
    esac
  done
  if ! { _gh_out="$(mktemp "${TMPDIR:-/tmp}/flow-gh.XXXXXX")" && _gh_err="$(mktemp "${TMPDIR:-/tmp}/flow-gh.XXXXXX")"; }; then
    # No room for the tries: one plain call, with the body it was given.
    if [ -n "$_gh_in" ]; then command gh "$@" < "$_gh_in"; else command gh "$@"; fi
    _gh_code=$?; rm -f "$_gh_out" ${_gh_in:+"$_gh_in"}; return "$_gh_code"
  fi
  for _gh_wait in ${FLOW_GH_RETRY_WAIT:-2 5} end; do
    if [ -n "$_gh_in" ]; then command gh "$@" < "$_gh_in" > "$_gh_out" 2> "$_gh_err"; else command gh "$@" > "$_gh_out" 2> "$_gh_err"; fi
    _gh_code=$?
    [ "$_gh_code" -ne 0 ] && [ "$_gh_wait" != end ] && gh_blip "$_gh_err" || break
    echo "flow: gh: $(head -n 1 "$_gh_err"); trying again in ${_gh_wait}s" >&2
    sleep "$_gh_wait"
  done
  cat "$_gh_out"; cat "$_gh_err" >&2
  rm -f "$_gh_out" "$_gh_err" ${_gh_in:+"$_gh_in"}
  return "$_gh_code"
}
# gh_blip <stderr file>: true when gh's error is GitHub's or the network's, not the call's.
# The same pattern as _call.py's BLIP; change both.
gh_blip() { grep -Eqi 'HTTP 5[0-9][0-9]|connection reset|connection refused|error connecting|timeout|unexpected EOF|: EOF$|stream error|GOAWAY|temporarily unavailable' "$1"; }

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

# The install set of plugin <root>: every file whose content init copies into a project, plus
# init.sh (it shapes the wrappers). Not the manifest: a version bump alone changes no installed
# file. init stamps its hash; the session-start hook compares.
flow_install_set() {
  for flow_install_set_file in "$1"/skills/init/scripts/init.sh "$1"/skills/init/migrations.json \
           "$1"/scripts/_config_*.py "$1"/templates/* "$1"/codex-agents/*.toml; do
    [ -f "$flow_install_set_file" ] && echo "$flow_install_set_file"
  done | sort
}
flow_source_hash() { hash_files $(flow_install_set "$1"); }

# main_worktree: the main worktree of the repository at the working folder, nothing outside one.
main_worktree() {
  if main_worktree_handed_down; then printf '%s\n' "$FLOW_MAIN_WORKTREE"; return; fi
  git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'
}
# main_worktree_handed_down: FLOW_MAIN_WORKTREE was found here on this PATH, with no git override.
main_worktree_handed_down() {
  [ "${FLOW_MAIN_WORKTREE_FOLDER:-}" = "$PWD" ] && [ "${FLOW_MAIN_WORKTREE_SEARCH_PATH:-}" = "$PATH" ] &&
    [ -n "${FLOW_MAIN_WORKTREE+set}" ] && ! git_repository_overridden
}
# git_repository_overridden: GIT_DIR, GIT_WORK_TREE or GIT_COMMON_DIR points git at a repository.
git_repository_overridden() { [ -n "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_COMMON_DIR:-}" ]; }
# main_worktree_resolve: finds the main worktree for this folder, unless handed down, and exports it.
main_worktree_resolve() {
  if main_worktree_handed_down || git_repository_overridden; then return 0; fi
  FLOW_MAIN_WORKTREE="$(main_worktree)"; FLOW_MAIN_WORKTREE_FOLDER="$PWD"; FLOW_MAIN_WORKTREE_SEARCH_PATH="$PATH"
  export FLOW_MAIN_WORKTREE FLOW_MAIN_WORKTREE_FOLDER FLOW_MAIN_WORKTREE_SEARCH_PATH
}
main_worktree_resolve

# The flow home holds the project config, the local items and the gate records. It is the main
# worktree's .flow, found from any linked worktree. FLOW_HOME overrides it (tests).
flow_home() {
  if [ -n "${FLOW_HOME:-}" ]; then printf '%s' "$FLOW_HOME"; return; fi
  main="$(main_worktree)"
  [ -n "$main" ] || main="$(pwd)"
  printf '%s/.flow' "$main"
}

# claude_hooks_present [root]: this user's Claude settings in the root name both flow worktree
# hooks. A plugin cannot provide them (the worktree is created before plugins load), so init
# writes them to .claude/settings.local.json and the session-start hook reports them missing.
claude_hooks_present() {
  _f="$(cat "${1:-.}/.claude/settings.local.json" 2>/dev/null)"
  printf '%s' "$_f" | grep -q 'worktree-create.sh' && printf '%s' "$_f" | grep -q 'worktree-remove.sh'
}

# flow_exclude: the clone's own ignore file, info/exclude in the common git directory. Every linked
# worktree of the clone reads it and it is never committed, so flow stays out of tracking.
flow_exclude() {
  _common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  printf '%s/info/exclude' "$(cd "$_common" && pwd)"
}

# codex_user_home: where Codex reads the user's own rules and agents, $CODEX_HOME or ~/.codex.
codex_user_home() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }

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

mkdir_exclusive() { cached_python3 -I -c 'import os, sys; os.mkdir(sys.argv[1])' "$1" 2>/dev/null; }

# flow_lock <name>: one holder at a time across sessions and unattended runs: a directory
# <flow home>/<name>.lock with the holder's pid. Waits up to FLOW_LOCK_WAIT seconds (default 60),
# then returns 1. A lock whose pid is gone is stale and taken over. flow_unlock releases it; so
# does the holder's exit.
flow_lock() {
  _flow_lock="$(flow_home)/$1.lock"; _waited=0
  mkdir -p "$(flow_home)"
  while ! mkdir_exclusive "$_flow_lock"; do
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

# adapter_for <id>: the adapter that owns an item: the one whose adapters/<name>/prefix starts the
# id (adapters/README.md).
adapter_for() {
  for _af_file in "$FLOW_PLUGIN"/adapters/*/prefix; do
    _af_prefix=""; read -r _af_prefix < "$_af_file" 2>/dev/null
    [ -n "$_af_prefix" ] || continue
    case "$1" in "$_af_prefix"*) _af_name="${_af_file%/prefix}"; printf '%s' "${_af_name##*/}"; return 0 ;; esac
  done
  return 1
}

# slug_item <slug>: the item id item_slug made the slug from, through each adapter's slug.sed;
# nothing when no adapter owns it.
slug_item() {
  for _si_file in "$FLOW_PLUGIN"/adapters/*/slug.sed; do
    [ -f "$_si_file" ] && printf '%s\n' "$1" | sed -n -f "$_si_file"
  done | head -n 1
}

# item_id_shaped <id>: 0 when an adapter owns the id (adapter_for) and the id has that adapter's
# shape: its slug.sed turns the id's slug back into the id itself (gh#<n>, local:<kind>/<n>,
# jira:<KEY>-<n>), so no path, space or `..` passes for an id.
item_id_shaped() {
  adapter_for "$1" >/dev/null || return 1
  [ "$(slug_item "$(item_slug "$1")")" = "$1" ]
}

# condition_in_grammar <condition>: 0 when it is one the health job reads: blocked_by:<id> of an
# item an adapter owns (item_id_shaped), pr:#<n> conflicting or ci:down.
condition_in_grammar() {
  _condition_pr="${1#pr:#}"; _condition_pr="${_condition_pr% conflicting}"
  case "$1" in
    ci:down) return 0 ;;
    blocked_by:*) item_id_shaped "${1#blocked_by:}"; return ;;
    "pr:#"*" conflicting") case "$_condition_pr" in ""|*[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  return 0
}

# adapter_for_kind <kind>: the adapter that new items of a kind go to, from the config.
adapter_for_kind() { v="$(cfg "adapters.$1")"; [ -n "$v" ] && printf '%s' "$v" || cfg_or "adapters.default" "local"; }

# adapters_configured: the trackers the flow reads, one per line: the config's `trackers` when it
# names them, else every adapter named under adapters.* and local. A name in trackers that is no
# adapter is refused, exit 2, with the adapters there are.
adapters_configured() {
  _trackers="$(cfg trackers)"
  if [ -z "$_trackers" ]; then
    { echo local; cfg "adapters.default"; for k in epic task bug; do cfg "adapters.$k"; done; } | grep -v '^$' | sort -u
    return
  fi
  for _tracker in $_trackers; do
    [ -d "$FLOW_PLUGIN/adapters/$_tracker" ] || die "trackers names $_tracker, not an adapter; the adapters are $(find "$FLOW_PLUGIN/adapters" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | paste -sd ' ' -)" 2
  done
  printf '%s\n' "$_trackers"
}

# trackers_unread: each adapters.* value that the config's `trackers` leaves out, one reason a
# line; nothing while trackers is unset. A new item sent there would never be read.
trackers_unread() {
  _trackers="$(cfg trackers)"; [ -n "$_trackers" ] || return 0
  for _key in default epic task bug; do
    _to="$(cfg "adapters.$_key")"; [ -n "$_to" ] || [ "$_key" != default ] || _to=local
    [ -z "$_to" ] || printf '%s\n' "$_trackers" | grep -qx "$_to" \
      || echo "adapters.$_key is $_to, which trackers leaves out, so the flow would never read the items it gets"
  done
}

# ready_rules: the readiness rules of every tracker, exported comma-separated: READY_NEEDS, the
# fields an unstarted item must have before it is ready (ready.needs), and READY_PRIORITY_ORDER,
# the priorities from most to least urgent (ready.priority_order). The deprecated
# github.ready_needs and github.priority_order stand in for a key the file leaves out (an empty
# list written there is kept), with one warning a run (FLOW_READY_WARNED keeps the scripts it
# starts quiet). A field no adapter knows is refused, exit 2.
READY_FIELDS="priority size"
ready_rules() {
  _needs_key=ready.needs; _old=""; _new=""
  READY_NEEDS="$(cfg ready.needs | paste -sd, -)"
  if [ -z "$(yaml_line "$(config_file)" ready.needs)" ]; then
    _needs_key=github.ready_needs; READY_NEEDS="$(cfg github.ready_needs | paste -sd, -)"
    [ -z "$READY_NEEDS" ] || { _old="github.ready_needs is"; _new="ready.needs"; }
  fi
  READY_PRIORITY_ORDER="$(cfg ready.priority_order | paste -sd, -)"
  if [ -z "$(yaml_line "$(config_file)" ready.priority_order)" ]; then
    READY_PRIORITY_ORDER="$(cfg github.priority_order | paste -sd, -)"
    [ -z "$READY_PRIORITY_ORDER" ] || { _old="${_old:+github.ready_needs and github.priority_order are}"; _old="${_old:-github.priority_order is}"; _new="${_new:+$_new and }ready.priority_order"; }
  fi
  if [ -n "$_old" ] && [ -z "${FLOW_READY_WARNED:-}" ]; then
    echo "flow: $_old deprecated: set $_new in .flow/config.yaml instead, read for every tracker" >&2
    FLOW_READY_WARNED=1
  fi
  for _need in $(printf '%s' "$READY_NEEDS" | tr , ' '); do
    case " $READY_FIELDS " in *" $_need "*) ;; *) die "$_needs_key knows $(printf '%s' "$READY_FIELDS" | sed 's/ / and /'), not $_need" 2 ;; esac
  done
  export READY_NEEDS READY_PRIORITY_ORDER FLOW_READY_WARNED
}

# Pick filters (pick.<name> in .flow/config.yaml) narrow the ready list `next --pick <name>` takes.
# A filter names tracker-neutral fields each adapter maps to its own in list (adapters/README.md):
# assignee (me, a login or an email), status, labels and kinds (lists: an item matches one of the
# values); trackers, the trackers next reads for it; or query, one tracker's own search as written,
# which takes no neutral field. Each adapter names the fields it maps in its pick-fields file.
PICK_NEUTRAL="assignee status labels kinds"

# pick_names: the filters the config names, one per line.
pick_names() { yaml_keys "$(config_file)" pick; }

# pick_check <name>: refuses, exit 2, a name the config does not have (saying the names it has), a
# tracker that is no adapter, and a query without exactly one tracker or beside a neutral field.
pick_check() {
  case "$1" in ""|*[!A-Za-z0-9_-]*) die "--pick takes a filter name from pick in .flow/config.yaml (letters, digits, _ and -), not '$1'" 2 ;; esac
  pick_names | grep -qx -- "$1" \
    || die "pick has no filter $1 in .flow/config.yaml; the filters are $(pick_names | paste -sd ' ' - | sed 's/^$/none/')" 2
  _pick_trackers="$(cfg "pick.$1.trackers")"
  for _tracker in $_pick_trackers; do
    [ -d "$FLOW_PLUGIN/adapters/$_tracker" ] || die "pick.$1.trackers names $_tracker, not an adapter; the adapters are $(find "$FLOW_PLUGIN/adapters" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | paste -sd ' ' -)" 2
  done
  [ -n "$(cfg "pick.$1.query")" ] || return 0
  [ "$(printf '%s\n' "$_pick_trackers" | grep -c .)" = 1 ] \
    || die "pick.$1.query is one tracker's own search: set pick.$1.trackers to exactly one tracker, not ${_pick_trackers:-none}" 2
  filter_query_alone "pick.$1" "$_pick_trackers"
}

# filter_query_alone <key> <tracker>: refuses, exit 2, a neutral field beside <key>.query, which
# goes to the tracker as written. An empty field is unset: Settings saves a field it clears as an
# empty value, not as no key.
filter_query_alone() {
  [ -n "$(cfg "$1.query")" ] || return 0
  for _alone_field in $PICK_NEUTRAL; do
    [ -z "$(cfg "$1.$_alone_field")" ] \
      || die "$1.query goes to $2 as written, so the filter takes no $_alone_field; put it in the query" 2
  done
}

# pick_mapped <name> <adapter>: refuses, exit 2, a field of the filter the adapter cannot map,
# saying the fields it maps (adapters/<adapter>/pick-fields).
pick_mapped() { filter_mapped "pick.$1" "$2"; }

# filter_mapped <key> <adapter>: refuses, exit 2, a field under <key> the adapter cannot map,
# saying the fields it maps (adapters/<adapter>/pick-fields); trackers is no field to map. An
# empty field is unset, so a cleared field the adapter cannot map is no refusal.
filter_mapped() {
  _mapped="$(cat "$FLOW_PLUGIN/adapters/$2/pick-fields" 2>/dev/null)"
  for _mapped_field in $(yaml_keys "$(config_file)" "$1"); do
    [ "$_mapped_field" = trackers ] || [ -z "$(cfg "$1.$_mapped_field")" ] && continue
    case " $_mapped " in *" $_mapped_field "*) ;; *) die "$1.$_mapped_field: the $2 adapter maps $(printf '%s' "${_mapped:-no field}" | sed 's/ /, /g; s/, \([^,]*\)$/ and \1/'), not $_mapped_field" 2 ;; esac
  done
}

# pick_trackers <name> <tracker>...: the trackers next reads for the filter, one per line: its
# trackers, else every one given (the trackers the flow reads). Refuses, exit 2, what pick_check
# refuses, a tracker the flow does not read, and a field one of the trackers cannot map.
pick_trackers() {
  _pick="$1"; shift
  pick_check "$_pick"
  _chosen="$(cfg "pick.$_pick.trackers")"
  for _tracker in $_chosen; do
    case " $* " in *" $_tracker "*) ;; *) die "pick.$_pick.trackers names $_tracker, which the flow does not read; it reads $*" 2 ;; esac
  done
  [ -n "$_chosen" ] || _chosen="$*"
  for _tracker in $_chosen; do pick_mapped "$_pick" "$_tracker"; printf '%s\n' "$_tracker"; done
}

# pick_filter <adapter> [args...]: the filter `--pick <name>` among an adapter list's arguments
# names, checked (pick_check, pick_mapped) and exported comma-separated for the adapter to map:
# FLOW_PICK_ASSIGNEE, FLOW_PICK_STATUS, FLOW_PICK_LABELS, FLOW_PICK_KINDS and FLOW_PICK_QUERY, each
# empty when the filter leaves it unset or no --pick is given. Returns 1 when the filter's
# trackers leave the adapter out, so its list is empty.
pick_filter() {
  _adapter="$1"; shift; _pick=""
  while [ $# -gt 0 ]; do
    if [ "$1" = --pick ]; then [ $# -ge 2 ] || die "--pick takes a filter name from pick in .flow/config.yaml" 2; _pick="$2"; fi
    shift
  done
  FLOW_PICK_ASSIGNEE=""; FLOW_PICK_STATUS=""; FLOW_PICK_LABELS=""; FLOW_PICK_KINDS=""; FLOW_PICK_QUERY=""
  export FLOW_PICK_ASSIGNEE FLOW_PICK_STATUS FLOW_PICK_LABELS FLOW_PICK_KINDS FLOW_PICK_QUERY
  [ -n "$_pick" ] || return 0
  pick_check "$_pick"
  _chosen="$(cfg "pick.$_pick.trackers")"
  [ -z "$_chosen" ] || printf '%s\n' "$_chosen" | grep -qx "$_adapter" || return 1
  pick_mapped "$_pick" "$_adapter"
  FLOW_PICK_ASSIGNEE="$(cfg "pick.$_pick.assignee")"; FLOW_PICK_QUERY="$(cfg "pick.$_pick.query")"
  FLOW_PICK_STATUS="$(cfg "pick.$_pick.status" | paste -sd, -)"
  FLOW_PICK_LABELS="$(cfg "pick.$_pick.labels" | paste -sd, -)"
  FLOW_PICK_KINDS="$(cfg "pick.$_pick.kinds" | paste -sd, -)"
}

# A tracker scope (<tracker>.scope in .flow/config.yaml) bounds every list of that tracker, and
# the flow runs no named item outside it. It takes the neutral fields a pick filter takes, or
# query alone, each as the tracker's adapter maps them (adapters/README.md); it belongs to its
# tracker, so it names no trackers. Every message names <tracker>.scope.

# scope_check <adapter>: refuses, exit 2, a scope that is no map of fields read two spaces in (a
# value, a list, fields no key of which reads), trackers in the scope, a field with lines under it
# no value of which reads (a map, a list at the field's own indent), a field the adapter does not
# map (pick-fields names neutral fields and query only, so this refuses any other field too) and a
# query beside a neutral field. An empty field is unset, and so is an empty scope.
scope_check() {
  [ -z "$(cfg "$1.scope")" ] \
    || die "$1.scope takes its fields on the lines under it, two spaces in, not a value or a list" 2
  if scope_written "$1" && [ -z "$(yaml_keys "$(config_file)" "$1.scope")" ]; then
    die "$1.scope: no field under it reads; put each field on its own line, two spaces in" 2
  fi
  [ -z "$(cfg "$1.scope.trackers")" ] \
    || die "$1.scope.trackers: a scope belongs to its tracker, so it names no trackers" 2
  scope_fields_read "$1"
  filter_mapped "$1.scope" "$1"
  filter_query_alone "$1.scope" "$1"
}

# scope_fields_read <adapter>: refuses, exit 2, a field under <adapter>.scope with lines under it
# no value of which reads (a map, a list at the field's own indent).
scope_fields_read() {
  for _scope_field in $(yaml_keys "$(config_file)" "$1.scope"); do
    [ -n "$(cfg "$1.scope.$_scope_field")" ] || ! yaml_nested "$(config_file)" "$1.scope.$_scope_field" \
      || die "$1.scope.$_scope_field: no value under it reads; put the value on its line, or each list item two spaces further in" 2
  done
}

# scope_filter <adapter>: the adapter's scope, checked (scope_check) when the config names a scope
# (scope_in_config), and exported comma-separated for the adapter to map beside a pick:
# FLOW_SCOPE_ASSIGNEE, FLOW_SCOPE_STATUS, FLOW_SCOPE_LABELS, FLOW_SCOPE_KINDS and
# FLOW_SCOPE_QUERY, each empty when the scope leaves it unset.
scope_filter() {
  FLOW_SCOPE_ASSIGNEE=""; FLOW_SCOPE_STATUS=""; FLOW_SCOPE_LABELS=""; FLOW_SCOPE_KINDS=""; FLOW_SCOPE_QUERY=""
  export FLOW_SCOPE_ASSIGNEE FLOW_SCOPE_STATUS FLOW_SCOPE_LABELS FLOW_SCOPE_KINDS FLOW_SCOPE_QUERY
  scope_in_config || return 0
  scope_check "$1"
  FLOW_SCOPE_ASSIGNEE="$(cfg "$1.scope.assignee")"; FLOW_SCOPE_QUERY="$(cfg "$1.scope.query")"
  FLOW_SCOPE_STATUS="$(cfg "$1.scope.status" | paste -sd, -)"
  FLOW_SCOPE_LABELS="$(cfg "$1.scope.labels" | paste -sd, -)"
  FLOW_SCOPE_KINDS="$(cfg "$1.scope.kinds" | paste -sd, -)"
}

# scope_in_config: 0 when a line of .flow/config.yaml outside a comment says scope, quoted or not;
# 1 says, with one grep, that no tracker has a scope.
scope_in_config() {
  grep -Eq '^[[:space:]]*([^#[:space:]].*)?scope' "$(config_file)" 2>/dev/null
}

# scope_written <adapter>: 0 when <adapter>.scope has a value or lines under it, however they read;
# an empty scope is unset.
scope_written() {
  [ -n "$(cfg "$1.scope")" ] || yaml_nested "$(config_file)" "$1.scope"
}

# scope_holds <item>: 0 when no adapter owns the item (an adhoc: name) or the config names no scope
# (scope_in_config); else the adapter's in-scope exit, which reads the scope as list does: 0 inside
# or with no scope, 1 outside and 3 when the tracker cannot say, each said on stderr, 2 for a scope
# scope_check refuses.
scope_holds() {
  _scope_adapter="$(adapter_for "$1")" && scope_in_config || return 0
  (adapter in-scope "$1"); _scope_code=$?
  case "$_scope_code" in
    1) echo "flow: $1 is outside $_scope_adapter.scope in .flow/config.yaml; the flow does not run it" >&2 ;;
    3) echo "flow: $_scope_adapter could not say whether $1 is inside $_scope_adapter.scope; the flow does not run it" >&2 ;;
  esac
  return "$_scope_code"
}

# scope_problems: what scope_check refuses in the scope of each tracker the flow reads, one line a
# tracker, for init --check; without the "<script>: " the caller's die puts first.
scope_problems() {
  for _scope_tracker in $(adapters_configured 2>/dev/null); do
    _scope_refusal="$(scope_check "$_scope_tracker" 2>&1 >/dev/null)" || printf '%s\n' "${_scope_refusal#*: }"
  done
}

# is_adapter_name <name>: 0 when <name> is a folder under adapters/: not empty, no leading dot,
# no slash.
is_adapter_name() {
  case "$1" in ""|.*|*/*) return 1 ;; esac
  [ -d "$FLOW_PLUGIN/adapters/$1" ]
}

# adapter <op> <id|adapter-name> [args...]: run one adapter operation. The first argument after
# the op is an item id (adapter from its prefix) or an adapter name (for list and list-ready): a
# folder under adapters/, never a path. Anything else dies, exit 2.
adapter() {
  op="$1"; who="$2"; shift 2
  if ! name="$(adapter_for "$who" 2>/dev/null)"; then
    is_adapter_name "$who" || die "no adapter owns $who, and it is no adapter name" 2
    name="$who"
  fi
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

# step_write <item> key=value...: adapter write-state, and when a step= pair is among them, the same
# step into the item's claim in the pool, so the claim and the issue never disagree while the
# item waits between runs. An item no pool worktree claims has no claim to follow.
step_write() {
  sw_item="$1"
  adapter write-state "$@" || return
  sw_step=""
  for sw_kv in "$@"; do case "$sw_kv" in step=*) sw_step="${sw_kv#step=}" ;; esac; done
  [ -n "$sw_step" ] || return 0
  sw_wt="$("$FLOW_PLUGIN/scripts/steward.sh" find "$sw_item" 2>/dev/null)"
  [ -n "$sw_wt" ] && [ -f "$sw_wt/.flow/claim.json" ] || return 0
  sw_new="$sw_wt/.flow/claim.json.$$"
  if json_set "$(cat "$sw_wt/.flow/claim.json")" step "$(json_string "$sw_step")" > "$sw_new" && [ -s "$sw_new" ]; then
    mv "$sw_new" "$sw_wt/.flow/claim.json"
  else
    rm -f "$sw_new"; echo "flow: could not write step $sw_step to the claim in $sw_wt" >&2
  fi
}

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

gate_known() { cached_python3 -I -c 'import json, sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["gates"] else 1)' "$FLOW_PLUGIN/profiles.json" "$1"; }
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
# path is empty). A quoted key reads as yaml_get reads it, without its quotes.
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
      if (key ~ /^".*"$/ || key ~ /^'\''.*'\''$/) key = substr(key, 2, length(key) - 2)
      if (found) { if (indent < depth) exit; if (indent == depth && index(body, ":")) print key; next }
      if (indent != depth) { if (indent < depth) exit; next }
      if (key != keys[depth + 1]) next
      depth = indent + 1
      if (depth == n) found = 1
    }' "$1"
}

# yaml_nested <file> <dotted.path>: 0 when lines sit under the key: indented deeper than it, or a
# block list at its own indentation.
yaml_nested() {
  _nested_at="$(yaml_line "$1" "$2")"
  [ -n "$_nested_at" ] || return 1
  awk -v at="$_nested_at" '
    NR == at { match($0, /^ */); key_indent = RLENGTH; next }
    NR < at || /^[ \t]*(#|$)/ { next }
    {
      match($0, /^ */)
      nested = RLENGTH > key_indent || (RLENGTH == key_indent && substr($0, RLENGTH + 1) ~ /^-( |$)/)
      exit
    }
    END { exit !nested }' "$1"
}

# yaml_inline_list <file> <dotted.path>: 0 when the key's value is an inline list as yaml_get reads
# it, its quotes stripped first, so a caller can refuse a value yaml_get would split into items.
yaml_inline_list() {
  _inline_at="$(yaml_line "$1" "$2")"
  [ -n "$_inline_at" ] || return 1
  awk -v at="$_inline_at" '
    NR == at {
      body = $0; sub(/^ */, "", body); sub(/[ \t]+#.*$/, "", body)
      value = substr(body, index(body, ":") + 1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) value = substr(value, 2, length(value) - 2)
      listed = value ~ /^\[/
      exit
    }
    END { exit !listed }' "$1"
}

# yaml_line <file> <dotted.path>: the line number of the key, quoted or not, empty when it is
# absent. For messages that point the owner at the line to fix.
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
      if (key ~ /^".*"$/ || key ~ /^'\''.*'\''$/) key = substr(key, 2, length(key) - 2)
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
    printf '%s' "$1" | cached_python3 -c '
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
