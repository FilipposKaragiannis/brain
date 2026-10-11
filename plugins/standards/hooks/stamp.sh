#!/bin/sh
# Install stamps. POSIX sh. Copied into each plugin by tools/generate.sh; edit shared/sh/stamp.sh.
# A stamp records what init last wrote into a project: the first line is
# "source<TAB><sha256 of the plugin's install set>", then one "<sha256><TAB><path>" line per
# installed copy. The session-start hook compares the source line with the plugin on disk (a few
# milliseconds); init compares each copy with its line to refuse replacing a hand edit.

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

hash_file() { hash_stdin < "$1"; }

hash_files() { cat "$@" | hash_stdin; }   # one hash over the files in the order given

stamp_source() { [ -f "$1" ] && awk -F'\t' 'NR == 1 && $1 == "source" { print $2 }' "$1"; }

stamp_get() { [ -f "$1" ] && awk -F'\t' -v p="$2" 'NR > 1 && $2 == p { print $1; exit }' "$1"; }
