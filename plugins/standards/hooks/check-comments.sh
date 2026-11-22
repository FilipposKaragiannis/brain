#!/bin/sh
# Block a commit that adds comments the standards forbid (C-01, C-02):
#   line comments (// in C#) only with an allowed marker, or when the message carries [why-comment]
#   (a math or physics why);
#   doc comments (/// in C#) only directly above a public declaration, or on a declaration inside
#   one of the comments.doc_inside type kinds (members there carry no modifier; interface and
#   enum when the key is absent, [] turns it off), or with [allow-docs]. Attribute lines between
#   the doc and the declaration are skipped.
# Comment tokens, the public keyword, the container kinds and the markers come from
# .standards/config.json per language.
. "$(dirname "$0")/lib.sh"
payload="$(read_payload)"
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0
seg="$(git_segment commit "$cmd")"
[ -n "$seg" ] || exit 0
cd "$(repo_root)" 2>/dev/null || exit 0
config="$(config_text)"
[ -n "$config" ] || exit 0
allow_line=0; allow_doc=0
commit_has_marker "$seg" "[why-comment]" && allow_line=1
commit_has_marker "$seg" "[allow-docs]" && allow_doc=1
[ "$allow_line" -eq 1 ] && [ "$allow_doc" -eq 1 ] && exit 0
diff_args="$(commit_diff_args "$seg")"
work_dir="$(mktemp -d)" || exit 0
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/content"
set -f
hits=""
count="$(json_length "$config" "languages")"
i=0
while [ "$i" -lt "$count" ]; do
  line_tok="$(json_get "$config" "languages.$i.comments.line")"
  doc_tok="$(json_get "$config" "languages.$i.comments.doc")"
  public_kw="$(json_get "$config" "languages.$i.comments.public")"
  markers="$(json_list "$config" "languages.$i.comments.allow_markers")"
  if [ -n "$(json_get "$config" "languages.$i.comments.doc_inside")" ]; then
    kinds="$(json_list "$config" "languages.$i.comments.doc_inside" | tr '\n' ' ')"
  else kinds="interface enum"; fi
  globs=""
  for ext in $(json_list "$config" "languages.$i.extensions"); do globs="$globs *$ext"; done
  i=$((i + 1))
  [ -n "$line_tok" ] && [ -n "$globs" ] || continue
  # shellcheck disable=SC2086
  diff="$(git diff $diff_args --diff-filter=ACMRT -U1 --no-color -- $globs 2>/dev/null || true)"
  [ -n "$diff" ] || continue
  # shellcheck disable=SC2086
  git diff $diff_args -z --name-only --diff-filter=ACMRT -- $globs > "$work_dir/names-nul" 2>/dev/null || true
  LC_ALL=C xargs -0 sh -c 'for name; do printf "%s\n%s\n" "${#name}" "$name"; done' sh < "$work_dir/names-nul" > "$work_dir/names"
  committed_content_root="./"
  if [ "$diff_args" = "--cached" ]; then
    git -c core.symlinks=false checkout-index -f -z --stdin --prefix="$work_dir/content/" < "$work_dir/names-nul" \
      || block "the staged content could not be read" "  git checkout-index failed on the staged files."
    committed_content_root="$work_dir/content/"
  fi
  found="$(printf '%s\n' "$diff" | LC_ALL=C awk -v line_tok="$line_tok" -v doc_tok="$doc_tok" -v pub="$public_kw" \
      -v markers="$markers" -v kinds="$kinds" -v committed_content_root="$committed_content_root" -v names_path="$work_dir/names" -v allow_line="$allow_line" -v allow_doc="$allow_doc" '
    BEGIN { nk = split(kinds, karr, " "); for (k = 1; k <= nk; k++) if (karr[k] != "") okkind[karr[k]] = 1 }
    function flush() { if (pending != "") { hits = hits pending; pending = "" } }
    function kind_of(l,   m) {
      if (match(l, /(^|[^A-Za-z0-9_])(interface|enum|class|struct|record)[ \t]+[A-Za-z_]/)) {
        m = substr(l, RSTART, RLENGTH); sub(/^[^A-Za-z]*/, "", m); sub(/[ \t].*$/, "", m); return m
      }
      return ""
    }
    function next_name(   byte_count, name, continuation) {
      if ((getline byte_count < names_path) <= 0) return ""
      getline name < names_path
      while (length(name) < byte_count) { getline continuation < names_path; name = name "\n" continuation }
      return name
    }
    function doc_allowed(file, line,   path, l, i, k, indentation, line_indent, kind, lines) {
      # True when the declaration at line, or the nearest enclosing type declaration (the first
      # type keyword above it at a smaller indentation), is one of the allowed kinds.
      if (nk == 0) return 0
      path = committed_content_root file
      i = 0; while ((getline l < path) > 0) lines[++i] = l
      close(path)
      if (line > i) return 0
      kind = kind_of(lines[line]); if (kind != "") return (kind in okkind)
      match(lines[line], /^[ \t]*/); indentation = RLENGTH
      for (k = line - 1; k >= 1; k--) {
        l = lines[k]; if (l ~ /^[ \t]*$/) continue
        match(l, /^[ \t]*/); line_indent = RLENGTH
        if (line_indent >= indentation) continue
        kind = kind_of(l); if (kind != "") return (kind in okkind)
      }
      return 0
    }
    function settle(body) {
      # The line after a doc block decides it: an attribute keeps it pending, a public or
      # container-covered declaration clears it, anything else reports it.
      if (body ~ /^[ \t]*\[/) return
      if (is_public(body) || doc_allowed(f, n)) pending = ""; else flush()
    }
    function allowed(b,   k, arr, m) {
      m = split(markers, arr, "\n")
      for (k = 1; k <= m; k++) if (arr[k] != "" && index(b, arr[k])) return 1
      return 0
    }
    function is_public(b) { return pub != "" && b ~ ("(^|[^A-Za-z0-9_])" pub "([^A-Za-z0-9_]|$)") }
    /^diff --git / { in_hunk = 0; if ($0 != previous_header) f = next_name(); previous_header = $0; next }
    !in_hunk && /^(---|\+\+\+) / { next }
    /^@@ /     { in_hunk = 1; flush(); if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/ {
      body = substr($0, 2)
      if (doc_tok != "" && index(body, doc_tok) && body !~ /:\/\/\//) {
        if (!allow_doc) pending = pending sprintf("  %s:%d  %s\n", f, n, body)
        n++; next
      }
      if (pending != "") settle(body)
      if (!allow_line && index(body, line_tok) && body !~ /:\/\// && !allowed(body))
        hits = hits sprintf("  %s:%d  %s\n", f, n, body)
      n++; next
    }
    /^ / { body = substr($0, 2); if (pending != "") settle(body); n++; next }
    /^-/ { flush(); next }
    END { flush(); printf "%s", hits }')" \
    || block "the comment check could not read the diff" "  awk failed on the diff of the staged files."
  hits="$hits$found"
done
[ -n "$hits" ] || exit 0
block "comments this commit adds break the standards" "$hits  C-01: no comments that explain code; a math or physics why needs [why-comment] in the message.
  C-02: doc comments only on public APIs and boundaries (public declarations, interface and enum members); elsewhere needs [allow-docs].
  Carry the intent in names, small types and test because strings instead."
