#!/bin/sh
# The project's own checks, run on a schedule: each key under jobs.checks in .flow/config.yaml is a
# check's name, with a command and a schedule under it. The check job (jobs/check.sh) runs one as
# the schedule check-<name>, in a clean checkout of the base under <flow home>/check-runs, a folder
# of its own: <flow home>/checks is verify's kept-pass store (lib/checks.sh), which sweeps its old
# files. Sourced after lib/flow.sh and lib/host.sh by scripts/jobs.sh, jobs/check.sh and init.sh,
# which each source lib/base.sh too.

check_runs_folder() { printf '%s/check-runs' "$(flow_home)"; }

# check_checkout <name>: the folder a run of the check checks the base out in. The schedule's lock
# lets one run of a check at a time, so one folder per check is enough.
check_checkout() { printf '%s/%s' "$(check_runs_folder)" "$1"; }

# check_output <name>: the file the last run's output went to, replaced each run.
check_output() { printf '%s/log/check-%s.out' "$(flow_home)" "$1"; }

# check_name_valid <name>: true for a lowercase letter, then lowercase letters and digits, the label
# every named schedule takes. The C locale, so no letter outside ASCII passes the ranges.
check_name_valid() { (LC_ALL=C; case "$1" in ''|[!a-z]*|*[!a-z0-9]*) exit 1 ;; esac); }

# check_command_listed <name>: true when the command's value starts with [, quoted or not, which
# the config reader takes for a list of items.
check_command_listed() {
  check_command_line="$(yaml_line "$(config_file)" "jobs.checks.$1.command")"
  [ -n "$check_command_line" ] || return 1
  sed -n "${check_command_line}p" "$(config_file)" | grep -q "^[^:]*:[[:space:]]*[\"']\{0,1\}\["
}

# check_entry_problem <name>: why the entry is no check by its name or its shape, or nothing.
check_entry_problem() {
  check_name_valid "$1" || { printf 'the name is a lowercase letter, then lowercase letters and digits (smoke, audit2)'; return; }
  [ -n "$(yaml_line "$(config_file)" "jobs.checks.$1")" ] || { printf 'is not set: add it with a command and a schedule'; return; }
  [ -z "$(cfg "jobs.checks.$1")" ] && yaml_nested "$(config_file)" "jobs.checks.$1" \
    || printf 'is no map: a check holds a command and a schedule under its name'
}

# check_fields_problem <name>: why the entry's command or schedule cannot run, or nothing. A check
# runs no agent, so its schedule is the timing alone: no args, no host word.
check_fields_problem() {
  [ -n "$(cfg "jobs.checks.$1.command")" ] || { printf 'has no command'; return; }
  ! check_command_listed "$1" || { printf 'its command starts with [, which the config reads as a list: start it another way, such as test'; return; }
  check_schedule="$(cfg "jobs.checks.$1.schedule")"
  [ -n "$check_schedule" ] || { printf 'has no schedule'; return; }
  python3 -I "$FLOW_PLUGIN/scripts/_jobs.py" check-schedule "$check_schedule"
}

# check_entry_line <name>: one line when the check's entry cannot run, naming its line in the
# config and why; nothing when it can.
check_entry_line() {
  check_problem_reason="$(check_entry_problem "$1")"
  [ -n "$check_problem_reason" ] || check_problem_reason="$(check_fields_problem "$1")"
  [ -z "$check_problem_reason" ] || printf '%s: jobs.checks.%s: %s\n' "$(host_cfg_where "jobs.checks.$1")" "$1" "$check_problem_reason"
}

# check_base_problem: one line when the config base, which every check checks out, fails
# base_name_valid, naming its line; the name stays out, as it may carry control characters.
check_base_problem() {
  base_name_valid "$(cfg_or base main)" \
    || printf '%s: base: is not a valid branch name, so no check can check it out\n' "$(host_cfg_where base)"
}

# check_problem <name>: one line when the check cannot run, by its entry (check_entry_line) or by
# the base (check_base_problem); nothing when it can.
check_problem() {
  check_entry_said="$(check_entry_line "$1")"
  if [ -n "$check_entry_said" ]; then printf '%s\n' "$check_entry_said"; else check_base_problem; fi
}

# checks_problems: one line per check the config sets that cannot run, as check_problem words it:
# jobs.checks set as a value, then each entry under it, then the base once when a check is set,
# then each jobs.schedule.check-<name> key, which jobs.sh leaves out of its schedules.
checks_problems() {
  [ -z "$(cfg jobs.checks)" ] \
    || printf '%s: jobs.checks: is no map: each check is a name under it, with a command and a schedule\n' "$(host_cfg_where jobs.checks)"
  listed_check_names="$(yaml_keys "$(config_file)" jobs.checks)"
  for listed_check_name in $listed_check_names; do check_entry_line "$listed_check_name"; done
  [ -z "$listed_check_names" ] || check_base_problem
  for scheduled_name in $(yaml_keys "$(config_file)" jobs.schedule); do
    case "$scheduled_name" in check-*)
      printf '%s: jobs.schedule.%s: a check is set under jobs.checks.%s, not jobs.schedule\n' \
        "$(host_cfg_where "jobs.schedule.$scheduled_name")" "$scheduled_name" "${scheduled_name#check-}" ;;
    esac
  done
}
