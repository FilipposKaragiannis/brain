#!/bin/sh
# Config migrations. POSIX sh. Copied into each plugin by tools/generate.sh; edit
# shared/sh/config_migration.sh. Sourced by init and the session-start hook only, never by the
# libraries every script loads.
# config_migrate <plugin name> <helper> <step list> <config file> runs the plugin's helper
# (`<helper> plan|apply <step list> <config file> <new label> [<out file>]`, exit 0 nothing to
# change, 1 changes, 2 cannot) and uses init's check, scratch, version, note and drifted. Under
# --check each pending change is a drift line and nothing is written. Otherwise the config is
# saved to <config dir>/migrations/<config name>.<label found>.bak (a name taken by other content
# gets .2, .3, ...), replaced by the migrated file, and the changes are appended to
# migrations/report.txt and to migrations/report.unseen, which the session-start hook prints once.
# The folder holds a .gitignore of *, so none of it is tracked. A config the helper cannot migrate,
# or one that changed after the helper read it, is named in a note and left as it is, with no
# backup and no report. A missing config has nothing to migrate.
# config_migration_report_once <plugin name> <config dir> prints <config dir>/migrations/
# report.unseen under a framing line and removes it, so each report shows in one session only. It
# claims the file with mv first, so of two sessions starting at once one prints it. It needs
# nothing from init.
# shellcheck disable=SC2154 # init, which sources it for config_migrate, sets check, scratch and version
config_migration_date_format='+%Y-%m-%d'
config_migration_first_extra_backup=2
config_migration_label_lines=1
config_migration_first_change_line=$((config_migration_label_lines + 1))

config_migrate() {
  config_migrate_plugin="$1"; config_migrate_helper="$2"; config_migrate_steps="$3"; config_migrate_config="$4"
  [ -f "$config_migrate_config" ] || return 0
  if [ "$check" -eq 1 ]; then
    config_migration_report_pending "$config_migrate_helper" "$config_migrate_steps" "$config_migrate_config"
    return 0
  fi
  config_migrate_out="$scratch/config-migration.out"; config_migrate_lines="$scratch/config-migration.lines"
  config_migrate_read="$scratch/config-migration.read"
  cp "$config_migrate_config" "$config_migrate_read" ||
    { echo "init: note: cannot read $config_migrate_config; it is not migrated"; return 0; }
  python3 -I "$config_migrate_helper" apply "$config_migrate_steps" "$config_migrate_config" "$version" "$config_migrate_out" \
    > "$config_migrate_lines" 2> "$scratch/config-migration.err"; config_migrate_code=$?
  [ "$config_migrate_code" -eq 0 ] && return 0
  if [ "$config_migrate_code" -ne 1 ] || [ ! -f "$config_migrate_out" ]; then
    echo "init: note: $(cat "$scratch/config-migration.err"); fix it and run init again"
    return 0
  fi
  cmp -s "$config_migrate_read" "$config_migrate_config" ||
    { echo "init: note: $config_migrate_config changed while init migrated it, so it is not migrated; run init again"; return 0; }
  config_migration_record "$config_migrate_plugin" "$config_migrate_config" "$config_migrate_out" "$config_migrate_lines"
}

config_migration_report_pending() {
  config_migration_report_pending_lines="$(python3 -I "$1" plan "$2" "$3" "$version" 2> "$scratch/config-migration.err")"
  config_migration_report_pending_code=$?
  [ "$config_migration_report_pending_code" -eq 0 ] && return 0
  if [ "$config_migration_report_pending_code" -ne 1 ]; then
    drifted "$(cat "$scratch/config-migration.err")"
    return 0
  fi
  while IFS= read -r config_migration_report_pending_change; do
    drifted "$3: pending migration: $config_migration_report_pending_change"
  done <<EOF_PENDING_MIGRATION
$(printf '%s\n' "$config_migration_report_pending_lines" | tail -n "+$config_migration_first_change_line")
EOF_PENDING_MIGRATION
}

config_migration_backup_name() {
  config_migration_backup_name_base="$1"; config_migration_backup_name_candidate="$1"
  config_migration_backup_name_number="$config_migration_first_extra_backup"
  while [ -e "$config_migration_backup_name_candidate" ] && ! cmp -s "$config_migration_backup_name_candidate" "$2"; do
    config_migration_backup_name_candidate="$config_migration_backup_name_base.$config_migration_backup_name_number"
    config_migration_backup_name_number=$((config_migration_backup_name_number + 1))
  done
  printf '%s' "$config_migration_backup_name_candidate"
}

config_migration_append() {
  { [ -f "$1" ] && cat "$1"; cat "$2"; } > "$3" && mv "$3" "$1"
}

config_migration_saved_backup() {
  config_migration_saved_backup_folder="$(dirname "$1")/migrations"
  mkdir -p "$config_migration_saved_backup_folder" || return 1
  [ -f "$config_migration_saved_backup_folder/.gitignore" ] || printf '*\n' > "$config_migration_saved_backup_folder/.gitignore"
  config_migration_saved_backup_name="$(config_migration_backup_name "$config_migration_saved_backup_folder/$(basename "$1").$2.bak" "$1")"
  [ -f "$config_migration_saved_backup_name" ] || cp "$1" "$config_migration_saved_backup_name" || return 1
  printf '%s' "$config_migration_saved_backup_name"
}

config_migration_append_report() {
  config_migration_append "$1/report.txt" "$2" "$scratch/config-migration.report" &&
    config_migration_append "$1/report.unseen" "$2" "$scratch/config-migration.unseen"
}

config_migration_record() {
  config_migration_record_config="$2"; config_migration_record_lines="$4"
  config_migration_record_folder="$(dirname "$config_migration_record_config")/migrations"
  config_migration_record_label="$(head -n "$config_migration_label_lines" "$config_migration_record_lines")"
  config_migration_record_backup="$(config_migration_saved_backup "$config_migration_record_config" "$config_migration_record_label")" ||
    { echo "init: note: cannot save $config_migration_record_config in $config_migration_record_folder; it is not migrated"; return 0; }
  mv "$3" "$config_migration_record_config" || { echo "init: note: cannot replace $config_migration_record_config; it is not migrated"; return 0; }
  config_migration_record_section="$scratch/config-migration.section"
  {
    echo "$1 $version migrated $config_migration_record_config on $(date -u "$config_migration_date_format") (it was at $config_migration_record_label; before: $config_migration_record_backup)"
    tail -n "+$config_migration_first_change_line" "$config_migration_record_lines"
    echo
  } > "$config_migration_record_section"
  config_migration_append_report "$config_migration_record_folder" "$config_migration_record_section" ||
    echo "init: note: cannot write the migration report in $config_migration_record_folder"
  note "$config_migration_record_config: migrated ($(($(wc -l < "$config_migration_record_lines") - config_migration_label_lines)) changes); before: $config_migration_record_backup; the changes: $config_migration_record_folder/report.txt"
}

config_migration_report_once() {
  config_migration_report_once_folder="$2/migrations"
  config_migration_report_once_unseen="$config_migration_report_once_folder/report.unseen"
  [ -f "$config_migration_report_once_unseen" ] || return 0
  config_migration_report_once_claimed="$config_migration_report_once_unseen.$$"
  mv "$config_migration_report_once_unseen" "$config_migration_report_once_claimed" 2>/dev/null || return 0
  echo "$1: note for the owner, not a task: $1:init migrated its config. Each line: old key, new key, value, reason. The record: $config_migration_report_once_folder/report.txt"
  sed '/^$/d; s/^/  /' "$config_migration_report_once_claimed"
  rm -f "$config_migration_report_once_claimed"
}
