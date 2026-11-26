#!/bin/sh
# tracker-untouched.sh: under the default tracker_state, an item run through every step of its
# profile leaves no flow state on its tracker, on the local adapter, the GitHub fake and the Jira
# fake. One driver, run_every_step, starts each step with next.sh, leaves the stub result its
# worker would, applies it with advance.sh and clears each gate with gate.sh, until next.sh says
# the item is done. Each item is re-sized at implement, where a size write would happen. After
# every call one check reads the tracker's raw store, never the adapter's state, which always
# carries defaults: the local item's frontmatter, the GitHub fake's issues.json, the Jira fake's
# jira.json. Status, assignee and Jira's flow-transition-target property are the tracker's own
# and are not asserted.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

next_step_ready=0
next_at_gate=4
next_item_done=6
advance_moved_on=0
advance_at_gate=4
advance_done=6
most_calls=40
made_size=M
made_profile=task-M
resize_step=implement
resized_to=S
resized_profile=task-S
pull_request_url="https://gh/pull/90"
github_state_marker="$(sed -n 's/^STATE_MARKER="\(.*\)"$/\1/p' "$plugin/adapters/github/_gh.sh")"

# stub_result <step>: the result file a worker leaves: verify's report, the pr step's PR, and the
# new size at the re-size step.
stub_result() {
  case "$1" in
    verify) printf '{"status":"pass"}\n' ;;
    pr) printf '{"status":"done","pr":"%s"}\n' "$pull_request_url" ;;
    "$resize_step") printf '{"status":"done","size":"%s"}\n' "$resized_to" ;;
    *) printf '{"status":"done"}\n' ;;
  esac
}
# expected_moves: the steps and gates of the run from profiles.json: the made profile up to the
# re-size step, then the steps the profile of the new size has after it.
expected_moves() { python3 -c 'import json, sys
profiles = json.load(open(sys.argv[1]))["profiles"]
before, after = profiles[sys.argv[2]], profiles[sys.argv[3]]
print(" ".join(before[:before.index(sys.argv[4]) + 1] + after[after.index(sys.argv[4]) + 1:]))' \
  "$plugin/profiles.json" "$made_profile" "$resized_profile" "$resize_step"; }
# moment_name <move> <what happened>: a check name's moment, as DesignStarts or PlanApprovalGateClears.
moment_name() { printf '%s %s' "$1" "$2" | awk -F '[- ]' '{ for (part = 1; part <= NF; part++) printf "%s%s", toupper(substr($part, 1, 1)), substr($part, 2) }'; }
# check_untouched <moment>: the one check after a call, on the store of the adapter being driven.
check_untouched() {
  check "${driven_adapter}ItemAfter$(moment_name "$1" "$2")_CarriesNoFlowState: because tracker_state none mirrors no record write to the tracker" \
    '"$driven_store_untouched" "$driven_item"'
}

# start_driven_step: next.sh on the driven item, its output in $driven_started and its exit in $driven_next_status.
start_driven_step() { driven_started="$("$plugin/scripts/next.sh" "$driven_item" --json 2>>"$work/flow.err")"; driven_next_status=$?; }
# run_started_step: the step next.sh started, run by its stub result and applied by advance.sh.
run_started_step() {
  driven_step="$(printf '%s' "$driven_started" | json_value step)"; driven_moves="$driven_moves $driven_step"
  check_untouched "$driven_step" starts
  stub_result "$driven_step" > "$(printf '%s' "$driven_started" | json_value reports)/$driven_step.json"
  "$plugin/scripts/advance.sh" "$driven_item" >/dev/null 2>>"$work/flow.err"; driven_advance_status=$?
  check_untouched "$driven_step" advances
  case "$driven_advance_status" in
    "$advance_moved_on"|"$advance_at_gate"|"$advance_done") ;;
    *) driven_stop="advance.sh at $driven_step exited $driven_advance_status"; return 1 ;;
  esac
}
# clear_raised_gate: the owner's answer to the gate the driven item waits at.
clear_raised_gate() {
  driven_gate="$(record get "$driven_item" gate)"; driven_moves="$driven_moves gate:$driven_gate"
  "$plugin/scripts/gate.sh" clear "$driven_item" "Go on." >/dev/null 2>>"$work/flow.err" \
    || { driven_stop="gate.sh clear at $driven_gate exited $?"; return 1; }
  check_untouched "$driven_gate" gate-clears
}
# run_every_step <adapter> <store check> <item>: the item through every step its profile has, the
# store check after each call. Leaves the steps and gates passed in $driven_moves, and why the run
# stopped short in $driven_stop, empty when next.sh said the item is done.
run_every_step() {
  driven_adapter="$1"; driven_store_untouched="$2"; driven_item="$3"
  driven_moves=""; driven_stop="still not done after $most_calls calls"; driven_call_count=0
  while [ "$driven_call_count" -lt "$most_calls" ]; do
    driven_call_count=$((driven_call_count + 1))
    start_driven_step
    case "$driven_next_status" in
      "$next_item_done") driven_stop=""; check_untouched last start; return 0 ;;
      "$next_at_gate") clear_raised_gate || return 1 ;;
      "$next_step_ready") run_started_step || return 1 ;;
      *) driven_stop="next.sh exited $driven_next_status"; return 1 ;;
    esac
  done
  return 1
}
# check_run_went_through <adapter>: the driven run ended done, through every step and gate expected.
check_run_went_through() {
  check "${1}ItemRunThroughEveryStep_EndsDone: because a run cut short would leave the checks above nothing to prove" \
    '[ -z "$driven_stop" ] || { echo "$driven_stop"; tail -n 5 "$work/flow.err"; false; }'
  check "${1}ItemRunThroughEveryStep_PassesEachStepAndGateOfItsProfiles: because the proof covers every call a run makes" \
    '[ "${driven_moves# }" = "$(expected_moves)" ] || { echo "passed: $driven_moves"; false; }'
  check "${1}ItemRunThroughEveryStep_RecordsTheNewSize: because the re-size happened, so a size write had a reason to land" \
    '[ "$(record get "$driven_item" size)" = "$resized_to" ]'
}
new_item() { "$plugin/scripts/new.sh" task "Run through every step" --size "$made_size" --body "$body"; }

# local_flow_keys <item>: the item file's frontmatter keys of the flow's state, size apart, as JSON.
local_flow_keys() { python3 -B -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import _item
meta, _ = _item.parse(sys.argv[2]); print(json.dumps({key: meta[key] for key in _item.STRIPPED_KEYS & set(meta)}, sort_keys=True))' \
  "$local_adapter" "$(item_file "$1")"; }
local_size() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import _item
meta, _ = _item.parse(sys.argv[2]); print(meta.get("size", ""))' "$local_adapter" "$(item_file "$1")"; }
# local_untouched <item>: the state keys are the ones create wrote, unchanged, and the size is as made.
local_untouched() { [ -n "$local_keys_made" ] && [ "$(local_flow_keys "$1")" = "$local_keys_made" ] && [ "$(local_size "$1")" = "$made_size" ]; }

echo "local: an item run through every step"
new_repo local
local_item="$(new_item)"
local_keys_made="$(local_flow_keys "$local_item")"
run_every_step Local local_untouched "$local_item"
check_run_went_through Local

# github_owned <item>: the issue's labels and fields in the fake's store, as JSON.
github_owned() { python3 -c 'import json, sys
issue = next(issue for issue in json.load(open(sys.argv[1]))["issues"] if "gh#%d" % issue["number"] == sys.argv[2])
print(json.dumps({"labels": issue["labels"], "fields": issue.get("fields")}, sort_keys=True))' "$FAKE_GH_DIR/issues.json" "$1"; }
# github_has_no_state_comment <item>: true when the issue was read and no comment on it carries the
# flow's state marker.
github_has_no_state_comment() { python3 -c 'import json, sys
issue = next(issue for issue in json.load(open(sys.argv[1]))["issues"] if "gh#%d" % issue["number"] == sys.argv[2])
sys.exit(1 if any(sys.argv[3] in comment["body"] for comment in issue.get("comments", [])) else 0)' "$FAKE_GH_DIR/issues.json" "$1" "$github_state_marker"; }
# github_untouched <item>: labels and fields as made, and no state comment.
github_untouched() {
  [ -n "$github_state_marker" ] && [ -n "$github_owned_made" ] && [ "$(github_owned "$1")" = "$github_owned_made" ] &&
    github_has_no_state_comment "$1"
}

echo "github: an item run through every step"
new_repo github
P="$plugin"; . "$here/_github_fixture.sh"
github_item="$(new_item)"
github_owned_made="$(github_owned "$github_item")"
check "GitHubItemMade_CarriesItsSizeLabel: because the size check compares against a store that holds the size" \
  'printf "%s" "$github_owned_made" | grep -q "\"size:$made_size\""'
run_every_step GitHub github_untouched "$github_item"
check_run_went_through GitHub

# jira_owned <item>: the issue's labels and the value of its size field in the fake's store, as JSON.
jira_owned() { python3 -c 'import json, sys
store = json.load(open(sys.argv[1])); fields = store["issues"][sys.argv[2].split(":", 1)[1]]["fields"]
size_field = next(field["id"] for field in store["fields"] if field["name"] == sys.argv[3])
print(json.dumps({"labels": fields["labels"], "size": fields.get(size_field)}, sort_keys=True))' "$jira_store" "$1" "$jira_size_field"; }
# jira_has_no_state_property <item>: true when the issue was read and holds no flow state property.
jira_has_no_state_property() { python3 -c 'import json, sys
sys.exit(1 if sys.argv[3] in json.load(open(sys.argv[1]))["issues"][sys.argv[2].split(":", 1)[1]]["properties"] else 0)' \
  "$jira_store" "$1" "$jira_state_property"; }
# jira_untouched <item>: labels and size field as made, and no state property.
jira_untouched() {
  [ -n "$jira_state_property" ] && [ -n "$jira_owned_made" ] && [ "$(jira_owned "$1")" = "$jira_owned_made" ] &&
    jira_has_no_state_property "$1"
}

echo "jira: an item run through every step"
new_repo jira
jira_size_field=Size
jira_state_property="$(sed -n 's/^STATE_PROPERTY = "\(.*\)"$/\1/p' "$plugin/adapters/jira/_jira.py")"
mkdir -p "$work/jira" "$work/jirabin" && cp "$plugin/tests/_fake_jira.py" "$work/jira/" && ln -s "$plugin/tests/fake-jira.sh" "$work/jirabin/curl"
jira_store="$work/jira/jira.json"; printf '{}\n' > "$jira_store"
PATH="$work/jirabin:$PATH" FAKE_JIRA_DIR="$work/jira" FLOW_JIRA_RETRY_WAIT="0 0" JIRA_API_TOKEN=run-token
export PATH FAKE_JIRA_DIR FLOW_JIRA_RETRY_WAIT JIRA_API_TOKEN
printf 'adapters:\n  default: jira\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\nnotify:\n  desktop: false\njira:\n  site: https://acme.atlassian.net\n  project: WID\n  email: flow@acme.test\n  fields:\n    size: %s\n' \
  "$jira_size_field" > .flow/config.yaml
jira_item="$(new_item)"
jira_owned_made="$(jira_owned "$jira_item")"
check "JiraItemMade_CarriesItsSizeInTheSizeField: because the size check compares against a store that holds the size" \
  'printf "%s" "$jira_owned_made" | grep -q "\"value\": \"$made_size\""'
run_every_step Jira jira_untouched "$jira_item"
check_run_went_through Jira

[ "$fails" -eq 0 ] && { echo "tracker-untouched: ok"; exit 0; }
echo "tracker-untouched: $fails failed"; exit 1
