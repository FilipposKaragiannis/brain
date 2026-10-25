#!/bin/sh
# One way to run a host CLI unattended, shared by the unattended loop and the jobs.
#   host_run <claude|codex> <dir> <prompt> [model] [effort] [roster|as-is]
# Claude: -p with jobs.permission_mode from .flow/config.yaml: dontAsk (the default) denies a
# tool outside the allow list instead of asking; auto lets the classifier allow the safe ones,
# so a run can edit files without an allow list. FLOW_PERMISSION_MODE overrides it. Codex: exec
# with workspace-write and the plugin hooks trusted for this invocation; the project rules
# file lets git and gh run outside the sandbox. The model names are the roster's (Claude
# names) and host_codex_model maps them for Codex, unless the last argument is as-is: the jobs
# pass the host's own names from jobs.<host>.model. Stdin is closed so a prompt never waits.
host_check() {
  case "${1:-}" in claude|codex) command -v "$1" >/dev/null 2>&1 || { echo "flow: $1 is not installed" >&2; return 1; } ;;
    *) echo "flow: host must be claude or codex" >&2; return 2 ;; esac
}
host_permission_mode() {
  _mode="${FLOW_PERMISSION_MODE:-}"
  if [ -z "$_mode" ]; then
    command -v cfg >/dev/null 2>&1 || . "$FLOW_PLUGIN/lib/flow.sh"
    _mode="$(cfg jobs.permission_mode)"
  fi
  case "${_mode:-dontAsk}" in dontAsk|auto) printf '%s' "${_mode:-dontAsk}" ;;
    *) echo "flow: jobs.permission_mode is dontAsk or auto, not $_mode" >&2; return 2 ;; esac
}
# host_skill_prompt <host> <plugin> <skill> <text>: a prompt that starts the skill as the owner
# would type it (/plugin:skill on Claude, $skill on Codex), then the text as its arguments. Most
# flow skills are user-invoked only, so a prompt asking the model to invoke one is refused.
host_skill_prompt() {
  case "$1" in codex) printf '$%s %s' "$3" "$4" ;; *) printf '/%s:%s %s' "$2" "$3" "$4" ;; esac
}
host_codex_model() { printf '%s' "$1" | sed 's/^sonnet$/gpt-6-luna/; s/^opus$/gpt-6-sol/; s/^fable$/gpt-6-astra/; s/^haiku$/gpt-6-luna/'; }
host_run() {
  host="$1"; dir="$2"; prompt="$3"; model="${4:-}"; effort="${5:-}"; names="${6:-roster}"
  case "$host" in
    claude)
      mode="$(host_permission_mode)" || return 2
      (cd "$dir" && claude -p "$prompt" --permission-mode "$mode" ${model:+--model "$model"} ${effort:+--effort "$effort"} < /dev/null) ;;
    codex)
      cmodel="$model"; [ "$names" = as-is ] || cmodel="$(host_codex_model "$model")"
      codex exec -C "$dir" -s workspace-write --dangerously-bypass-hook-trust -c 'approval_policy="never"' \
        ${cmodel:+-m "$cmodel"} ${effort:+-c "model_reasoning_effort=\"$effort\""} "$prompt" < /dev/null ;;
    *) echo "flow: host must be claude or codex" >&2; return 2 ;;
  esac
}

# The jobs' model and effort, per host, from .flow/config.yaml: jobs.<host>.model and
# jobs.<host>.effort, passed to the host as is; empty is the host's own default (no flag). A
# config with no jobs.<host> map falls back to jobs.model and jobs.effort (deprecated in 1.20.0,
# read for one release), whose roster names host_codex_model maps for Codex.
host_efforts() { case "$1" in claude) printf 'low medium high xhigh max' ;; codex) printf 'low medium high xhigh' ;; esac; }
host_efforts_said() { case "$1" in claude) printf 'low, medium, high, xhigh or max' ;; codex) printf 'low, medium, high or xhigh' ;; esac; }
host_jobs_has_pair() { yaml_keys "$(config_file)" jobs | grep -qx "$1"; }
host_jobs_legacy() { [ -n "$(cfg jobs.model)$(cfg jobs.effort)" ]; }
# host_jobs_pair <host>: sets jobs_model and jobs_effort for the host, and jobs_from, the key
# prefix they came from (jobs.<host>, or jobs for the fallback).
host_jobs_pair() {
  if host_jobs_has_pair "$1"; then
    jobs_from="jobs.$1"; jobs_model="$(cfg "jobs.$1.model")"; jobs_effort="$(cfg "jobs.$1.effort")"
  else
    jobs_from=jobs; jobs_model="$(cfg jobs.model)"; jobs_effort="$(cfg jobs.effort)"
    [ "$1" != codex ] || jobs_model="$(host_codex_model "$jobs_model")"
  fi
}
host_cfg_where() { _l="$(yaml_line "$(config_file)" "$1")"; printf '.flow/config.yaml%s' "${_l:+:$_l}"; }
# host_jobs_host_problem: a line when jobs.host is set to something other than claude or codex.
host_jobs_host_problem() {
  _jh="$(cfg jobs.host)"
  case "${_jh:-claude}" in claude|codex) ;; *)
    printf '%s: jobs.host is %s; it must be claude or codex\n' "$(host_cfg_where jobs.host)" "$_jh" ;; esac
}
# host_jobs_pair_problem <host>: a line when the host's effort (or the fallback's) is one it
# does not take.
host_jobs_pair_problem() {
  host_jobs_pair "$1"
  [ -n "$jobs_effort" ] || return 0
  case " $(host_efforts "$1") " in *" $jobs_effort "*) return 0 ;; esac
  printf '%s: %s.effort is %s; %s takes %s, or empty for its default\n' "$(host_cfg_where "$jobs_from.effort")" "$jobs_from" "$jobs_effort" "$1" "$(host_efforts_said "$1")"
}
# host_jobs_problems: one line per bad jobs value, with its line in the config: jobs.host, then
# the pair of every jobs.<host> map present and of the jobs.host one (the fallback when absent).
host_jobs_problems() {
  host_jobs_host_problem
  _jh="$(cfg jobs.host)"; case "$_jh" in claude|codex) ;; *) _jh=claude ;; esac
  for _x in $( (for _y in claude codex; do host_jobs_has_pair "$_y" && echo "$_y"; done; echo "$_jh") | sort -u); do
    host_jobs_pair_problem "$_x"
  done
}
