#!/bin/sh
# verify.sh <item> [--base <ref>]: the one verify run. From the claimed worktree, runs in order
# build, format (changed files only), tests, mutation (signal, never a fail) and the project
# gates from .flow/config.yaml (gates: name: command), each once, and writes
# <reports>/verify.json {status, checks: [{name, status, command, summary}], attempts, base,
# head, changed_files, feel_test} and its Markdown twin verify.md for the PR body. Commands come
# from .standards/config.json (build, test, mutation, languages[].format). feel_test is true
# when a changed file matches feel_test_paths in the flow config. Never edits anything.
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
checks=""; overall="pass"; sep=""

run_check() {
  # run_check <name> <command> <kind: gate|signal> [files]
  name="$1"; command="$2"; kind="$3"; files="${4:-}"
  cmd="$(printf '%s' "$command" | sed "s|{files}|$files|g")"
  printf '\n== %s: %s\n' "$name" "$cmd" >> "$log"
  if out="$(sh -c "$cmd" 2>&1)"; then st="pass"; summary="ok"
  else
    st="fail"; [ "$kind" = "signal" ] && st="signal"
    summary="$(printf '%s' "$out" | grep -v '^$' | tail -5 | tr '\n' ' ' | cut -c1-400)"
  fi
  printf '%s\n' "$out" >> "$log"
  [ "$st" = "fail" ] && overall="fail"
  checks="$checks$sep$(json_obj "name=$name" "status=$st" "command=$cmd" "summary=$summary")"; sep=","
}

build="$(json_get "$std" build)"
[ -n "$build" ] && run_check build "$build" gate || checks="$checks$sep$(json_obj name=build status=skipped command= "summary=no build command in .standards/config.json")" ; [ -n "$build" ] || sep=","
nlang="$(json_length "$std" languages)"; i=0; ran_format=0
while [ "$i" -lt "${nlang:-0}" ]; do
  lang="$(json_get "$std" "languages.$i")"
  exts="$(json_list "$lang" extensions | tr '\n' '|' | sed 's/|$//; s/\./\\./g')"
  nf="$(json_length "$lang" format)"; j=0
  while [ "$j" -lt "${nf:-0}" ]; do
    prefix="$(json_get "$lang" "format.$j.prefix")"; command="$(json_get "$lang" "format.$j.command")"
    files="$(printf '%s\n' "$changed" | grep -E "($exts)$" | { [ -n "$prefix" ] && grep "^$prefix" || cat; } | while read -r f; do [ -f "$f" ] && printf '%s ' "$f"; done)"
    if [ -n "$files" ]; then run_check "format${prefix:+ $prefix}" "$command" gate "$files"; ran_format=1; fi
    j=$((j + 1))
  done
  i=$((i + 1))
done
[ "$ran_format" -eq 1 ] || { checks="$checks$sep$(json_obj name=format status=skipped command= "summary=no changed source files under a format rule")"; sep=","; }
test_cmd="$(json_get "$std" test)"
if [ -n "$test_cmd" ]; then run_check tests "$test_cmd" gate; else checks="$checks$sep$(json_obj name=tests status=skipped command= "summary=no test command in .standards/config.json")"; sep=","; fi
mutation="$(json_get "$std" mutation)"
[ -n "$mutation" ] && run_check mutation "$mutation" signal
for name in $(yaml_keys "$(config_file)" gates); do
  command="$(cfg "gates.$name")"
  [ -n "$command" ] && run_check "gate $name" "$command" gate
done
feel=false
for g in $(cfg feel_test_paths); do
  printf '%s\n' "$changed" | while read -r f; do glob_match "$g" "$f" && exit 3; done
  [ $? -eq 3 ] && { feel=true; break; }
done
files_json="$(printf '%s\n' "$changed" | python3 -I -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')"
json_obj "status=$overall" "checks:=[$checks]" "attempts=$attempts" "base=$base" "head=$(git rev-parse --short HEAD)" "changed_files:=$files_json" "feel_test:=$feel" \
  | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2))' > "$reports/verify.json"
{
  echo "## Verify: $overall (attempt $attempts)"
  echo
  echo "| check | status | summary |"; echo "|---|---|---|"
  printf '%s' "[$checks]" | python3 -I -c '
import json, sys
for c in json.load(sys.stdin):
    print("| %s | %s | %s |" % (c["name"], c["status"], c["summary"].replace("|", "\\|")[:200]))'
  echo
  echo "Base \`$base\` ($merge_base), head \`$(git rev-parse --short HEAD)\`, $(printf '%s\n' "$changed" | grep -c .) changed files. Log: \`$log\`."
  [ "$feel" = true ] && echo "**Feel-test needed:** a changed file matches \`feel_test_paths\`."
} > "$reports/verify.md"
echo "verify: $overall (attempt $attempts); report $reports/verify.json"
[ "$overall" = "pass" ]
