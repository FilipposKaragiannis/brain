# slow_steps.sh: the health job's word on the steps that got slower. Sourced by scripts/steward.sh,
# whose cmd_health calls health_slow_steps once a pass. The graph report alone decides which step
# got slower (scripts/graph-report.sh --slower names the steps its verdict names); a step is said
# and notified once while it stays slower, and said again after it recovered and slowed down anew.
# A report that fails is one finding, said once per error, and the pass goes on. No model runs,
# and the report keeps no history on this call, so a pass every few minutes costs one read of the
# run log. Sourced, never run.

SLOW_STEP_PERIOD_DAYS=7
SLOW_STEP_KEY_PREFIX=slower-step-
SLOW_STEP_REPORT_KEY=slower-steps-report
SLOW_STEP_STATE=slower

slow_step_key() { printf '%s%s' "$SLOW_STEP_KEY_PREFIX" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-')"; }

health_slow_step() {
  health_changed "$(slow_step_key "$1")" "$SLOW_STEP_STATE" || return 0
  slow_step_finding="$1 got slower: its median run took $2 in the last $SLOW_STEP_PERIOD_DAYS days, up from $3 in the $SLOW_STEP_PERIOD_DAYS days before"
  health_say pool "the step $slow_step_finding"
  health_notify "The step $slow_step_finding. graph-report.sh shows its runs."
}

health_slow_steps_cleared() {
  for slow_step_seen_file in "$home/health/$SLOW_STEP_KEY_PREFIX"*.seen; do
    [ -f "$slow_step_seen_file" ] || continue
    slow_step_seen_key="$(basename "$slow_step_seen_file" .seen)"
    printf '%s\n' "$1" | grep -qxF "$slow_step_seen_key" || health_cleared "$slow_step_seen_key"
  done
}

health_slow_steps() {
  slow_steps_error_file="$home/health/.slow-steps.$$"
  if ! slow_steps_found="$("$FLOW_PLUGIN/scripts/graph-report.sh" --days "$SLOW_STEP_PERIOD_DAYS" --slower 2>"$slow_steps_error_file")"; then
    slow_steps_error="$(tail -n 1 "$slow_steps_error_file")"; rm -f "$slow_steps_error_file"
    health_changed "$SLOW_STEP_REPORT_KEY" "$slow_steps_error" && health_say pool "the graph report failed, so no slower step is said this run: $slow_steps_error"
    return 0
  fi
  rm -f "$slow_steps_error_file"; health_cleared "$SLOW_STEP_REPORT_KEY"
  slow_step_keys=""
  while IFS="$(printf '\t')" read -r slow_step slow_step_now slow_step_before; do
    [ -n "$slow_step" ] || continue
    slow_step_keys="$slow_step_keys$(slow_step_key "$slow_step")
"
    health_slow_step "$slow_step" "$slow_step_now" "$slow_step_before"
  done <<EOF
$slow_steps_found
EOF
  health_slow_steps_cleared "$slow_step_keys"
}
