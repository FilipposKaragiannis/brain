# _verify_base_fixture.sh: the fixture verify-base-trust.sh and verify-base-choice.sh source, on
# top of _verify_fixture.sh: the report readers, an item with one changed source file
# (changed_source_item), the tests its standards run and an epic slice claimed on its parent's
# branch. Sourced after _verify_fixture.sh, never run.
# shellcheck disable=SC2034,SC2154 # the suites that source it read its names and set the ones it reads
report_missing="no such report or key"
# report_value <key>: the report's value at the key, JSON for one that is not a string, or
# report_missing when the report or the key is missing, so an empty value is never a missing one.
report_value() { python3 -c 'import json,sys
try: value=json.load(open(sys.argv[1]))[sys.argv[2]]
except (OSError, ValueError, KeyError): value=sys.argv[3]
print(value if isinstance(value,str) else json.dumps(value))' "$reports/verify.json" "$1" "$report_missing"; }
check_field() { python3 -c 'import json,sys; found=[check for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]]; print(found[0].get(sys.argv[3], "") if found else "no such check")' "$reports/verify.json" "$1" "$2"; }
feel_test() { report_value feel_test; }
report_base() { report_value base; }
# summary_names_the_cause <text>: true when the failed `changed files` check's summary holds the text.
summary_names_the_cause() { check_field "changed files" summary | grep -qF -- "$1"; }
current_branch() { git -C "$worktree" symbolic-ref -q HEAD | sed 's|^refs/heads/||'; }
commit_notes() { echo note > "$worktree/notes.txt" && git -C "$worktree" add notes.txt && git -C "$worktree" commit -qm "notes"; }
# changed_source_item <dir> <standards json> <committed|staged|untracked>: new_item with feel-test
# paths under ui/, the standards committed and source/file.sh changed as named.
changed_source_item() {
  new_item "$1" ""
  printf 'feel_test_paths:\n  - ui/**\n' >> .flow/config.yaml
  mkdir -p "$worktree/.standards" "$worktree/source"
  printf '%s\n' "$2" > "$worktree/.standards/config.json"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "standards"
  echo change > "$worktree/source/file.sh"
  case "$3" in
    committed) git -C "$worktree" add source/file.sh && git -C "$worktree" commit -qm "source change" ;;
    staged) git -C "$worktree" add source/file.sh ;;
  esac
}
failing_scoped_test='{"test":[{"name":"scoped","command":"false {verify_base}","paths":["source/**"]}]}'
whole_tree_test='{"test":[{"name":"whole","command":"true"}]}'
verify_failed_exit=1
refused_checks="changed files,tests scoped"
# claimed_slice_of <epic item>: a new slice of the item, claimed on its branch; prints the slice.
claimed_slice_of() {
  claimed_slice_item="$("$local_adapter/create.sh" task "Slice of $1" --size S --body x --parent "$1")" && "$plugin/scripts/next.sh" "$claimed_slice_item" >/dev/null 2>&1 && printf '%s' "$claimed_slice_item"
}
scoped_source_change() { mkdir -p "$1/.standards" "$1/source" && printf '%s\n' "$failing_scoped_test" > "$1/.standards/config.json" && echo change > "$1/source/file.sh"; }
