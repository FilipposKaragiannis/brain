# _cost_hosts_fixture.sh: the claude and codex stubs in $work/costbin that print what each host prints, and
# cpath, the PATH that puts them first. Takes $work. Sourced after _flow_setup.sh, never run.
# Host stubs that print what each host prints with the flags host_run passes: Claude one result
# object, Codex one event per line. FAKE_HOST picks the session: ok does the step (it writes the
# report the brief names), budget and auth fail as the hosts do on a spend limit and a login,
# other fails on something else, quote ends well with text that quotes a limit, silent ends well
# and writes no report (a session whose writes were all denied).
mkdir -p "$work/costbin"; export COST_LOG="$work/cost.log"
cat > "$work/costbin/claude" <<'STUB'
#!/bin/sh
printf 'claude\tttl=%s/%s\t%s\n' "${CLAUDE_CODE_PROMPT_CACHE_TTL:-}" "${CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL:-}" "$*" >> "$COST_LOG"
case "${FAKE_HOST:-ok}" in
  budget) echo '{"type":"result","subtype":"success","is_error":true,"result":"API Error: 422 {\"type\":\"error\",\"error\":{\"type\":\"ExceededBudget\",\"message\":\"The seat reached its spend limit.\"}}","total_cost_usd":0}'; exit 1 ;;
  auth) echo '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}'; exit 1 ;;
  window) python3 -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":True,"result":sys.argv[1],"total_cost_usd":0}))' "$FAKE_HOST_SAID"; exit 1 ;;
  other) echo '{"type":"result","subtype":"success","is_error":true,"result":"Prompt is too long"}'; exit 1 ;;
  errors) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Credit balance is too low"]}'; exit 1 ;;
  model) echo '[claude-code:unrecognized_model] {"model":"claude-nope-9","query_source":"sdk"}' >&2
         echo '{"type":"result","subtype":"success","is_error":true,"result":"There'"'"'s an issue with the selected model (claude-nope-9). It may not exist or you may not have access to it. Run --model to pick a different model.","total_cost_usd":0}'; exit 1 ;;
  quote) echo '{"type":"result","subtype":"success","is_error":false,"result":"Done. The old log said: Credit balance is too low."}'; exit 0 ;;
  silent) echo '{"type":"result","subtype":"success","is_error":false,"result":"Every write was denied, so no report was written."}'; exit 0 ;;
esac
brief="$(printf '%s' "$*" | sed -n 's/.*Follow the brief in \([^ ]*\) .*/\1/p')"
report="$(sed -n 's/^Write `\(.*\)`:$/\1/p' "$brief" 2>/dev/null | head -1)"
[ -z "$report" ] || { mkdir -p "$(dirname "$report")" && printf '{"status":"done","summary":"stub"}\n' > "$report"; }
echo '{"type":"result","subtype":"success","is_error":false,"result":"did the step","total_cost_usd":0.25,"usage":{"input_tokens":120,"output_tokens":30,"cache_creation_input_tokens":400,"cache_read_input_tokens":900},"modelUsage":{"claude-jobs-x":{"costUSD":0.25}}}'
STUB
cat > "$work/costbin/codex" <<'STUB'
#!/bin/sh
printf 'codex\t\t%s\n' "$*" >> "$COST_LOG"
case "${FAKE_HOST:-ok}" in
  auth) echo '{"type":"thread.started","thread_id":"t"}'
        echo '{"type":"error","message":"unexpected status 401 Unauthorized: Your access token could not be refreshed"}'
        echo '{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}'; exit 1 ;;
  model) echo '{"type":"thread.started","thread_id":"t"}'
         echo '{"type":"turn.failed","error":{"message":"status 400 model_not_found: The gpt-nope-9 model is not supported when using Codex with a ChatGPT account."}}'; exit 1 ;;
esac
brief="$(printf '%s' "$*" | sed -n 's/.*Follow the brief in \([^ ]*\) .*/\1/p')"
report="$(sed -n 's/^Write `\(.*\)`:$/\1/p' "$brief" 2>/dev/null | head -1)"
[ -z "$report" ] || { mkdir -p "$(dirname "$report")" && printf '{"status":"done","summary":"stub"}\n' > "$report"; }
echo '{"type":"thread.started","thread_id":"t"}'
echo '{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"did the step"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":20,"output_tokens":5}}'
STUB
chmod +x "$work/costbin/claude" "$work/costbin/codex"
cpath="$work/costbin:$PATH"
