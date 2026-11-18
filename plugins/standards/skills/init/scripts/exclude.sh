#!/bin/sh
# init.sh, machine scope, sourced after the roster: keeps the clone's own outputs out of git status
# with a marked block in the clone's info/exclude, which git never tracks. The block names
# /.standards (no trailing slash, so a linked worktree's link to it matches too) and every
# project-level path this run wrote or kept: the rendered roster agents and the skills and rules
# links. A re-run replaces the block in place; the lines around it stay. It uses init's check,
# drifted, note, tmpfile, stamped, kept, project_skills and project_rules.
exclude_begin="# standards:begin"
exclude_end="# standards:end"
excluded_paths() {
  echo /.standards
  printf '%s' "$stamped$kept" | while IFS= read -r written_path; do
    case "$written_path" in /*|.standards/*) ;; *) echo "/$written_path" ;; esac
  done
  if [ -n "$project_skills" ]; then printf '/.claude/skills\n/.agents/skills\n'; fi
  if [ -n "$project_rules" ]; then echo /.claude/rules/project; fi
}
install_exclude() {
  mkdir -p "${exclude_file%/*}" && cat "$wanted_exclude" > "$exclude_file" && note "$exclude_file: standards block"
}
exclude_file="$(git rev-parse --git-common-dir)/info/exclude"
exclude_block="$(tmpfile exclude-block)"
{ echo "$exclude_begin"; excluded_paths; echo "$exclude_end"; } > "$exclude_block"
wanted_exclude="$(tmpfile exclude)"
if [ -f "$exclude_file" ] && grep -qxF "$exclude_begin" "$exclude_file"; then
  BEGIN_LINE="$exclude_begin" END_LINE="$exclude_end" BLOCK="$exclude_block" awk '
    $0 == ENVIRON["BEGIN_LINE"] { while ((getline line < ENVIRON["BLOCK"]) > 0) print line; inside_block = 1; next }
    inside_block && $0 == ENVIRON["END_LINE"] { inside_block = 0; next }
    !inside_block { print }' "$exclude_file" > "$wanted_exclude"
else
  {
    if [ -s "$exclude_file" ]; then cat "$exclude_file"; [ -z "$(tail -c 1 "$exclude_file")" ] || echo; fi
    cat "$exclude_block"
  } > "$wanted_exclude"
fi
if [ ! -f "$exclude_file" ] || ! cmp -s "$wanted_exclude" "$exclude_file"; then
  repair "$exclude_file standards block" install_exclude
fi
