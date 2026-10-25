#!/bin/sh
# verify.sh <item> [--base <ref>]: the one verify run. From the claimed worktree, runs in order
# build, format (changed files only), tests, mutation (signal, never a fail) and the project
# gates from .flow/config.yaml, each once, and writes
# <reports>/verify.json {status, checks: [{name, status, command, summary}], attempts, base,
# head, changed_files, feel_test} and its Markdown twin verify.md for the PR body. Commands come
# from .standards/config.json (build, test, mutation, languages[].format). An empty mutation is
# the off switch (a skipped check); a mutation command with {files} runs on the changed source
# files only, like a format command, and is skipped when none changed. A project gate is
# `name: command` (always runs) or a map with `command:` and `paths:` (runs when a changed file
# matches a glob; otherwise a skipped check). feel_test is true when a changed file matches
# feel_test_paths in the flow config. Never edits anything. The report is built from data by
# scripts/_verify_report.py and renamed into place, so it is never empty or half written; when it
# cannot be built, verify says why on stderr, writes a minimal report with status fail and the
# cause as a check summary, and exits 1.
. "$(dirname "$0")/../lib/flow.sh"
[ $# -ge 1 ] || die "usage: verify.sh <item> [--base <ref>]" 2
item="$1"; shift
base=""
while [ $# -gt 0 ]; do case "$1" in --base) base="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac; done
root="$(repo_root)" || die "not in a git repository"
cd "$root" || exit 1
[ -n "$base" ] || base="$(cfg_or base main)"
ref="$base"; git show-ref --verify --quiet "refs/remotes/origin/$base" && ref="origin/$base"
merge_base="$(git merge-base "$ref" HEAD 2>/dev/null || echo "$ref")"
changed="$(git diff --name-only "$merge_base" HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)"
changed="$(printf '%s\n' "$changed" | grep -v '^$' | grep -v '^\.flow/' | sort -u)"
std=""; [ -f .standards/config.json ] && std="$(cat .standards/config.json)"
reports="$(reports_dir "$item" "$root")"; mkdir -p "$reports"
log="$reports/verify.log"; : > "$log"
data="$(adapter read "$item" 2>/dev/null)" || data='{}'
attempts="$(state_get "$data" attempts)"; attempts=$(( ${attempts:-0} + 1 ))
overall="pass"
records="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
changed_list="$(mktemp "${TMPDIR:-/tmp}/flow-verify.XXXXXX")" || die "cannot make a temp file"
trap 'rm -f "$records" "$changed_list"' EXIT

record() {
  # record <name> <status> <command> <summary source>: one check, four NUL-terminated fields. The
  # report builder turns the source into the summary; nothing here is JSON.
  printf '%s\000%s\000%s\000%s\000' "$1" "$2" "$3" "$4" >> "$records"
}
skipped() {
  # skipped <name> <why>: a check that did not apply, kept in the report so the reader sees why.
  record "$1" skipped "" "$2"
}
changed_matches() {
  # changed_matches <globs, one per line>: true when a changed file matches one of them.
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && glob_match "$g" "$f" && return 0
    done <<EOF_FILES
$changed
EOF_FILES
  done <<EOF_GLOBS
$1
EOF_GLOBS
  return 1
}

run_check() {
  # run_check <name> <command> <kind: gate|signal> [files]
  name="$1"; command="$2"; kind="$3"; files="${4:-}"
  cmd="$(printf '%s' "$command" | sed "s|{files}|$files|g")"
  printf '\n== %s: %s\n' "$name" "$cmd" >> "$log"
  if out="$(sh -c "$cmd" 2>&1)"; then st="pass"; summary="ok"
  else
    st="fail"; [ "$kind" = "signal" ] && st="signal"
    summary="$out"
  fi
  printf '%s\n' "$out" >> "$log"
  [ "$st" = "fail" ] && overall="fail"
  record "$name" "$st" "$cmd" "$summary"
}

build="$(json_get "$std" build)"
if [ -n "$build" ]; then run_check build "$build" gate; else skipped build "no build command in .standards/config.json"; fi
nlang="$(json_length "$std" languages)"; i=0; ran_format=0; all_files=""
while [ "$i" -lt "${nlang:-0}" ]; do
  lang="$(json_get "$std" "languages.$i")"
  exts="$(json_list "$lang" extensions | tr '\n' '|' | sed 's/|$//; s/\./\\./g')"
  nf="$(json_length "$lang" format)"; j=0
  while [ "$j" -lt "${nf:-0}" ]; do
    prefix="$(json_get "$lang" "format.$j.prefix")"; command="$(json_get "$lang" "format.$j.command")"
    files="$(printf '%s\n' "$changed" | grep -E "($exts)$" | { [ -n "$prefix" ] && grep "^$prefix" || cat; } | while read -r f; do [ -f "$f" ] && printf '%s ' "$f"; done)"
    if [ -n "$files" ]; then run_check "format${prefix:+ $prefix}" "$command" gate "$files"; ran_format=1; all_files="$all_files$files"; fi
    j=$((j + 1))
  done
  i=$((i + 1))
done
[ "$ran_format" -eq 1 ] || skipped format "no changed source files under a format rule"
test_cmd="$(json_get "$std" test)"
if [ -n "$test_cmd" ]; then run_check tests "$test_cmd" gate; else skipped tests "no test command in .standards/config.json"; fi
mutation="$(json_get "$std" mutation)"
if [ -z "$mutation" ]; then skipped mutation "mutation is empty in .standards/config.json (off)"
else
  case "$mutation" in
    *'{files}'*) if [ -n "$all_files" ]; then run_check mutation "$mutation" signal "$all_files"; else skipped mutation "no changed source files for the mutation run"; fi ;;
    *) run_check mutation "$mutation" signal ;;
  esac
fi
for name in $(yaml_keys "$(config_file)" gates); do
  command="$(cfg "gates.$name")"; paths=""
  if [ -z "$command" ]; then command="$(cfg "gates.$name.command")"; paths="$(cfg "gates.$name.paths")"; fi
  [ -n "$command" ] || continue
  if [ -n "$paths" ] && ! changed_matches "$paths"; then skipped "gate $name" "no changed file under its paths"; continue; fi
  run_check "gate $name" "$command" gate
done
feel=false
for g in $(cfg feel_test_paths); do
  printf '%s\n' "$changed" | while read -r f; do glob_match "$g" "$f" && exit 3; done
  [ $? -eq 3 ] && { feel=true; break; }
done
printf '%s\n' "$changed" > "$changed_list"
head_sha="$(git rev-parse --short HEAD)"

report_failed() {
  # report_failed <cause>: the report builder failed. Say so, and leave a minimal report that
  # still parses, with status fail and the cause, written without the builder and renamed in.
  cause="$(printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | LC_ALL=C tr -d '"\\' | cut -c1-400)"
  safe() { printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._/-'; }
  echo "verify: could not build the report: $cause" >&2
  printf '{"status": "fail", "checks": [{"name": "report", "status": "fail", "command": "", "summary": "could not build the report: %s"}], "attempts": %d, "base": "%s", "head": "%s", "changed_files": [], "feel_test": false}\n' \
    "$cause" "$attempts" "$(safe "$base")" "$(safe "$head_sha")" > "$reports/.verify.json.$$.tmp" && mv -f "$reports/.verify.json.$$.tmp" "$reports/verify.json"
  printf '## Verify: fail (attempt %d)\n\nThe report could not be built: %s\n\nLog: `%s`.\n' "$attempts" "$cause" "$log" \
    > "$reports/.verify.md.$$.tmp" && mv -f "$reports/.verify.md.$$.tmp" "$reports/verify.md"
  exit 1
}
err="$(python3 -I "$FLOW_PLUGIN/scripts/_verify_report.py" "$records" "$changed_list" "$reports" "$overall" "$attempts" "$base" "$merge_base" "$head_sha" "$feel" "$log" 2>&1 >/dev/null)" \
  || report_failed "$(printf '%s\n' "${err:-the report builder exited non-zero}" | grep -v '^ ' | tail -1 | tr '\n' ' ')"
echo "verify: $overall (attempt $attempts); report $reports/verify.json"
[ "$overall" = "pass" ]
