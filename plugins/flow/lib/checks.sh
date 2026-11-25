#!/bin/sh
# The test commands verify has passed, kept by the key of their inputs, so a command that passed
# on the same command text and the same files is not run again. A build is never kept: its outputs
# are ignored files the key does not cover. Sourced after
# lib/flow.sh by scripts/verify.sh. The store is <flow home>/checks: every worktree of the clone
# reads it and it is never committed. One file per key (scripts/_checks.py key), one line:
# `<time> <item> <head>`, the run the pass came from.

# The days a kept pass stays in the store.
CHECKS_KEPT_DAYS=30

checks_store() { printf '%s/checks' "$(flow_home)"; }

# check_key <command> <globs, one per line>: the key of the command's inputs at HEAD, empty when a
# file under the globs has an uncommitted change or the key cannot be worked out.
check_key() {
  printf '%s\n' "$2" | cached_python3 -I "$FLOW_PLUGIN/scripts/_checks.py" key "$1" 2>/dev/null
}

# check_key_valid <key>: true for a key _checks.py prints, so nothing else names a file in the store.
check_key_valid() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; }

# check_passed <key>: prints the run a kept pass of the key came from (`<time> <item> <head>`),
# with nothing but the characters a time, an item id and a commit hold; 1 when none is kept.
check_passed() {
  check_key_valid "$1" || return 1
  kept_pass="$(sed -n 1p "$(checks_store)/$1" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9:#/._ -')"
  [ -n "$kept_pass" ] || return 1
  printf '%s' "$kept_pass"
}

# check_keep <key> <item> <head>: keeps the pass of the key, written to a new file and renamed in,
# and drops every pass kept longer than CHECKS_KEPT_DAYS. An empty key keeps nothing.
check_keep() {
  check_key_valid "$1" || return 0
  mkdir -p "$(checks_store)" || return 0
  kept_file="$(mktemp "$(checks_store)/.kept.XXXXXX")" || return 0
  printf '%s %s %s\n' "$(now_iso)" "$2" "$3" > "$kept_file" && mv -f "$kept_file" "$(checks_store)/$1" || rm -f "$kept_file"
  find "$(checks_store)" -type f -mtime "+$CHECKS_KEPT_DAYS" -exec rm -f {} + 2>/dev/null
  return 0
}

# check_drop <key>: drops the kept pass of the key, as a run of the same inputs failed since.
check_drop() { check_key_valid "$1" && rm -f "$(checks_store)/$1"; return 0; }
