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
# Claude's sessions write the 5-minute prompt cache (CLAUDE_CODE_PROMPT_CACHE_TTL, and its
# subagent twin): a session that ends in minutes never uses the hour a subscription would buy at
# twice the write price. A TTL the owner exported wins.
# Both hosts print JSON (claude --output-format json, codex --json), which scripts/_host.py turns
# back into the text they would have printed; stderr streams as it comes. After the run,
# host_usage holds the usage the host reported as JSON (with cost_usd and the models that ran),
# empty when it reported none, and host_cause is spend-limit or auth when the session failed on
# one, with host_said the host's line. That cause stops the host (host_stop): every later host_run
# on it refuses, exit 75, until the owner clears it (gate.sh clear).
command -v flow_home >/dev/null 2>&1 || . "$FLOW_PLUGIN/lib/flow.sh"
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
  host_usage=""; host_cause=""; host_said=""
  case "$host" in claude|codex) ;; *) echo "flow: host must be claude or codex" >&2; return 2 ;; esac
  _stop="$(host_stopped "$host")"
  [ -z "$_stop" ] || { echo "flow: $_stop" >&2; return 75; }
  [ "$host" != claude ] || { mode="$(host_permission_mode)" || return 2; }
  _hr="$(mktemp "${TMPDIR:-/tmp}/flow-host.XXXXXX")" || return 1
  # stdout to a file for _host.py, stderr through tee: to the caller as it comes, and kept.
  { { case "$host" in
      claude)
        (cd "$dir" && CLAUDE_CODE_PROMPT_CACHE_TTL="${CLAUDE_CODE_PROMPT_CACHE_TTL:-5m}" \
          CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL="${CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL:-5m}" \
          claude -p "$prompt" --output-format json --permission-mode "$mode" ${model:+--model "$model"} ${effort:+--effort "$effort"} < /dev/null) ;;
      codex)
        cmodel="$model"; [ "$names" = as-is ] || cmodel="$(host_codex_model "$model")"
        codex exec --json -C "$dir" -s workspace-write --dangerously-bypass-hook-trust -c 'approval_policy="never"' \
          ${cmodel:+-m "$cmodel"} ${effort:+-c "model_reasoning_effort=\"$effort\""} "$prompt" < /dev/null ;;
    esac; echo $? > "$_hr.code"; } 2>&1 1>&3 | tee "$_hr.err" >&2; } 3> "$_hr"
  _code="$(cat "$_hr.code" 2>/dev/null)"; _code="${_code:-1}"
  python3 -I "$FLOW_PLUGIN/scripts/_host.py" "$host" "$_hr" "$_hr.err" "$_code" "$_hr.sum"
  if [ -s "$_hr.sum" ]; then
    _sum="$(cat "$_hr.sum")"
    host_cause="$(json_get "$_sum" cause)"; host_said="$(json_get "$_sum" said)"
    [ -z "$(json_get "$_sum" usage)$(json_get "$_sum" cost_usd)" ] || host_usage="$_sum"
  fi
  rm -f "$_hr" "$_hr.err" "$_hr.code" "$_hr.sum"
  [ -z "$host_cause" ] || host_stop "$host" "$host_cause" "$host_said"
  return "$_code"
}

# A host stopped on a spend limit or an auth error starts no session until the owner clears it:
# <flow home>/log/<host>.stopped holds the cause, the host's line, when, and the item whose gate
# names it (host_stop_item, once the caller raised one). gate.sh clear on that item, or on the
# host's name, removes it.
host_stop_file() { printf '%s/log/%s.stopped' "$(flow_home)" "$1"; }
# host_stop <host> <cause> <said>: the first stop wins; a later one keeps it. The owner is told
# at once, unless the caller raises a gate that tells them (FLOW_HOST_GATES=1, the unattended loop).
host_stop() {
  _f="$(host_stop_file "$1")"
  [ ! -f "$_f" ] || return 0
  mkdir -p "$(dirname "$_f")"
  json_obj "host=$1" "cause=$2" "said=$3" "at=$(now_iso)" "item=" > "$_f"
  [ "${FLOW_HOST_GATES:-}" = 1 ] || "$FLOW_PLUGIN/scripts/notify.sh" --event host-stopped \
    "$1 stopped on $(host_cause_said "$2"): $3. No $1 session starts until you clear it. $(host_stop_fix "$1" "$2"), then: gate.sh clear $1" >/dev/null 2>&1 || true
}
# host_stop_item <host> <item>: the item whose gate names the stop; the first one keeps it.
host_stop_item() {
  _f="$(host_stop_file "$1")"
  [ -f "$_f" ] || return 0
  _s="$(cat "$_f")"
  [ -z "$(json_get "$_s" item)" ] || return 0
  json_obj "host=$1" "cause=$(json_get "$_s" cause)" "said=$(json_get "$_s" said)" "at=$(json_get "$_s" at)" "item=$2" > "$_f"
}
# host_cause_said <cause>: the cause in words.
host_cause_said() { case "$1" in spend-limit) printf 'a spend limit' ;; auth) printf 'an auth error' ;; *) printf '%s' "$1" ;; esac; }
# host_stop_fix <host> <cause>: what the owner does before clearing, with no full stop.
host_stop_fix() {
  case "$2" in
    auth) printf 'Sign %s in again (%s)' "$1" "$([ "$1" = codex ] && echo 'codex login' || echo 'claude, then /login')" ;;
    *) printf 'Raise the limit or wait for its reset' ;;
  esac
}
# host_stopped <host>: a line saying why the host starts no session, or nothing when it may.
host_stopped() {
  _f="$(host_stop_file "$1")"
  [ -f "$_f" ] || return 0
  _s="$(cat "$_f")"; _it="$(json_get "$_s" item)"
  printf '%s is stopped since %s on %s: %s. No %s session starts until %s.' "$1" "$(json_get "$_s" at)" \
    "$(host_cause_said "$(json_get "$_s" cause)")" "$(json_get "$_s" said)" "$1" \
    "$([ -n "$_it" ] && echo "the gate on $_it clears (gate.sh clear $_it)" || echo "you clear it (gate.sh clear $1)")"
}

# host_record <item> <step> <model> <effort> <started epoch> <exit>: one line per step session in
# <flow home>/log/runs.jsonl, after host_run: the item, the step, the host, the model and effort
# it was given (empty: the host's default), when and how long, the exit, the usage and cost the
# host reported, the models that ran, and in result the stop cause when there was one. The line
# has no job key, so the job readers (scripts/jobs.sh, the health job) pass over it.
host_record() {
  _result=""; [ -z "${host_cause:-}" ] || _result="$host_cause: ${host_said:-}"
  mkdir -p "$(flow_home)/log"
  printf '%s' "${host_usage:-}" | python3 -I -c 'import json, sys, time
item, step, host, model, effort, t0, code, result = sys.argv[1:9]
try:
    u = json.load(sys.stdin)
except ValueError:
    u = {}
t0 = int(t0)
print(json.dumps({"item": item, "step": step, "host": host, "model": model, "effort": effort,
                  "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)), "seconds": int(time.time()) - t0,
                  "exit": int(code), "usage": u.get("usage"), "cost_usd": u.get("cost_usd"),
                  "models": u.get("models") or [], "result": result}))' "$1" "$2" "$host" "$3" "$4" "$5" "$6" "$_result" >> "$(flow_home)/log/runs.jsonl"
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
