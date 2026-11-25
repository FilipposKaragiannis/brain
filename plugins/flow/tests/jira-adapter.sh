#!/bin/sh
# jira-adapter.sh: the Jira adapter and its tracker scope, through a fake curl.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
echo "jira adapter (fake curl)"
cp .flow/config.yaml "$work/config.gh"
mkdir -p "$work/jira" "$work/jirabin" && cp "$P/tests/_fake_jira.py" "$work/jira/" && ln -s "$P/tests/fake-jira.sh" "$work/jirabin/curl"
printf '{"transitions": [{"id": "31", "name": "Done", "category": "done"}, {"id": "41", "name": "Closed", "category": "done"}]}\n' > "$work/jira/jira.json"
jira_config() { printf 'adapters:\n  default: jira\nbase: main\nnotify:\n  desktop: false\njira:\n  site: %s\n  project: WID\n  email: flow@acme.test\n  api_token: in-the-config\n  fields:\n    size: Size\n  transitions:\n    done: Closed\n' "$1" > .flow/config.yaml; }
jira_run() { env PATH="$work/jirabin:$PATH" FAKE_JIRA_DIR="$work/jira" FLOW_JIRA_RETRY_WAIT="0 0" JIRA_API_TOKEN=run-token "$@"; }
jira_db() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$work/jira/jira.json" "$1"; }
jira_config https://acme.atlassian.net
env PATH="$work/jirabin:$PATH" FAKE_JIRA_DIR="$work/jira" "$P/adapters/jira/list.sh" > /dev/null 2> "$work/jira/refused.err"; code=$?
check_all "jira: without JIRA_API_TOKEN the adapter refuses and says why, though the config holds a token" '[ "$code" -ne 0 ] && grep -q "JIRA_API_TOKEN is not set" "$work/jira/refused.err" && [ ! -s "$work/jira/calls.log" ]'
jira_task="$(jira_run "$P/adapters/jira/create.sh" task "Sized" --size M)"
check_all "jira: a size goes to the jira.fields.size field, not a label" '[ "$(jira_db "d[\"issues\"][\"${jira_task#jira:}\"][\"fields\"][\"customfield_10040\"][\"value\"]")" = M ] && [ "$(jira_db "d[\"issues\"][\"${jira_task#jira:}\"][\"fields\"][\"labels\"]")" = "[]" ] && [ "$(jira_run "$P/adapters/jira/read.sh" "$jira_task" | jget size)" = M ]'
jira_run "$P/adapters/jira/write-state.sh" "$jira_task" size=L step=implement
check_all "jira: write-state moves the size field and labels the step" '[ "$(jira_run "$P/adapters/jira/read.sh" "$jira_task" | jget state.size)" = L ] && [ "$(jira_db "d[\"issues\"][\"${jira_task#jira:}\"][\"fields\"][\"labels\"]")" = "['"'"'step:implement'"'"']" ]'
jira_run "$P/adapters/jira/write-state.sh" "$jira_task" size=
check_all "jira: write-state size= clears the jira.fields.size field" '[ "$(jira_db "d[\"issues\"][\"${jira_task#jira:}\"][\"fields\"][\"customfield_10040\"]")" = None ] && [ -z "$(jira_run "$P/adapters/jira/read.sh" "$jira_task" | jget size)" ]'
jira_run "$P/adapters/jira/link-pr.sh" "$jira_task" https://gh/pr/9
check "jira: link-pr adds the PR as a remote link" [ "$(jira_db "[l[\"object\"][\"url\"] for l in d[\"issues\"][\"${jira_task#jira:}\"][\"remotelinks\"]]")" = "['https://gh/pr/9']" ]
jira_run "$P/adapters/jira/close.sh" "$jira_task"
check "jira: close takes the jira.transitions.done transition" [ "$(jira_db "d[\"issues\"][\"${jira_task#jira:}\"][\"fields\"][\"status\"][\"name\"]")" = Closed ]
check "jira: the token never reaches curl's command line" sh -c "! grep -q run-token '$work/jira/calls.log'"
printf '1\n503\n/rest/api/3/issue$\n' > "$work/jira/fail"
check_all "jira: a create that met a 5xx is not tried again, as it may have landed" '! jira_run "$P/adapters/jira/create.sh" task "Twice" 2>/dev/null && [ "$(jira_db "len(d[\"issues\"])")" = 1 ] && [ "$(grep -c "/rest/api/3/issue\$" "$work/jira/calls.log")" = 2 ]'
jira_blocker="$(jira_run "$P/adapters/jira/create.sh" task "Blocker")"
printf '1\n403\n/rest/api/3/issueLink\n' > "$work/jira/fail"
jira_held="$(jira_run "$P/adapters/jira/create.sh" task "Held" --blocked-by "$jira_blocker" 2>/dev/null)"
check_all "jira: a blocker whose link Jira refused still holds the new task" '[ "$(jira_run "$P/adapters/jira/read.sh" "$jira_held" | jget blocked_by)" = "[\"$jira_blocker\"]" ] && jira_run "$P/adapters/jira/list-ready.sh" | python3 -c "import json,sys; ids=[i[\"id\"] for i in json.load(sys.stdin)]; sys.exit(0 if sys.argv[1] in ids and sys.argv[2] not in ids else 1)" "$jira_blocker" "$jira_held"'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
d["issues"]["WID-90"] = {"key": "WID-90", "properties": {}, "comments": [], "remotelinks": [], "fields": {"summary": "Linked", "labels": [], "priority": None,
  "status": {"name": "To Do", "statusCategory": {"key": "new"}}, "issuetype": {"name": "Task"},
  "description": {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [
    {"type": "text", "text": "the spec", "marks": [{"type": "link", "attrs": {"href": "https://docs.test/spec"}}]},
    {"type": "text", "text": " and "}, {"type": "inlineCard", "attrs": {"url": "https://acme.atlassian.net/browse/WID-7"}}]}]}}}
json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json"
check_all "jira: a description keeps its link targets and smart links" '[ "$(jira_run "$P/adapters/jira/read.sh" jira:WID-90 | jget body)" = "[the spec](https://docs.test/spec) and https://acme.atlassian.net/browse/WID-7" ]'
# A filter narrows the list to two epics whose three open children it leaves out; jira.limit 2
# must not cut the child count short, or the second epic reads as having none, and as ready.
jira_config https://acme.atlassian.net
printf '  limit: 2\npick:\n  epics:\n    labels: [picked]\n' >> .flow/config.yaml
pe1="$(jira_run "$P/adapters/jira/create.sh" epic "Picked epic one")"; pe2="$(jira_run "$P/adapters/jira/create.sh" epic "Picked epic two")"
for parent in "$pe1" "$pe1" "$pe2"; do jira_run "$P/adapters/jira/create.sh" task "Unpicked child" --parent "$parent" >/dev/null; done
python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for key in sys.argv[2:]: d["issues"][key]["fields"]["labels"] = ["picked"]
json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json" "${pe1#jira:}" "${pe2#jira:}"
picked_children="$(jira_run "$P/adapters/jira/list.sh" --pick epics | python3 -c 'import json,sys; counts={i["id"]: i["open_children"] for i in json.load(sys.stdin)}; print(counts.get(sys.argv[1]), counts.get(sys.argv[2]))' "$pe1" "$pe2")"
check "jira: a filter's epics count every open child, past jira.limit" [ "$picked_children" = "2 1" ]
check "jira: so an epic with an open child the filter left out is not ready" sh -c "! env PATH='$work/jirabin:$PATH' FAKE_JIRA_DIR='$work/jira' FLOW_JIRA_RETRY_WAIT='0 0' JIRA_API_TOKEN=run-token '$P/adapters/jira/list-ready.sh' --pick epics | grep -q '\"$pe2\"'"
jira_config http://acme.atlassian.net
site_err="$(jira_run "$P/adapters/jira/list.sh" 2>&1 >/dev/null)"; code=$?
check_all "jira: a jira.site that is not https is refused" '[ "$code" -ne 0 ] && printf "%s" "$site_err" | grep -q "jira.site in .flow/config.yaml must be"'
# jira_area_config [jira lines]: an area field and the given lines (answer_from) under jira.
jira_area_config() { printf 'adapters:\n  default: jira\nbase: main\nnotify:\n  desktop: false\njira:\n  site: https://acme.atlassian.net\n  project: WID\n  email: flow@acme.test\n  fields:\n    area: Area\n%s' "${1:-}" > .flow/config.yaml; }
# jira_comment_as <id> <email> <text>: a comment written by that user straight into the fake's store.
jira_comment_as() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["issues"][sys.argv[2]]["comments"]
c.append({"id": str(len(c) + 1), "author": {"accountId": "acct-" + sys.argv[3].split("@")[0], "emailAddress": sys.argv[3]},
  "body": {"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [{"type": "text", "text": sys.argv[4]}]}]}})
json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json" "${1#jira:}" "$2" "$3"; }
jira_area_config
check_all "jira vocabulary: the project's issue types without sub-tasks, and the options of the area field" '[ "$(jira_run "$P/adapters/jira/vocabulary.sh")" = "{\"types\": [\"Epic\", \"Task\", \"Bug\", \"Story\", \"Feature\"], \"areas\": [\"Bots\", \"Debugging\"]}" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["createmeta_page"]=1; json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json"
check_all "jira vocabulary: the area field on a later page of the create metadata is still found" '[ "$(jira_run "$P/adapters/jira/vocabulary.sh" | jget areas)" = "[\"Bots\", \"Debugging\"]" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("createmeta_page"); json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json"
jira_gated="$(jira_run "$P/adapters/jira/create.sh" task "Gated")"
jira_comment_as "$jira_gated" flow@acme.test "/answer before the gate"
jira_run "$P/scripts/gate.sh" raise "$jira_gated" ambiguity "1. Which way?" >/dev/null 2>&1
jira_comment_as "$jira_gated" stranger@acme.test "/answer the stranger's way"
jira_comment_as "$jira_gated" flow@acme.test "thinking about it"
jira_owner_answer="the owner's way"
jira_comment_as "$jira_gated" flow@acme.test "/answer $jira_owner_answer"
check_all "JiraAnsweredGate_PrintsItsId: answers prints the id of the gate the token user's /answer cleared, because the job logs each id it prints" '[ "$(jira_run "$P/adapters/jira/answers.sh" "$jira_gated")" = "$jira_gated" ]'
check_all "JiraAnsweredGate_TakesTheOwnersWords: the record's answer is the owner's latest /answer after the gate, not a stranger's or an earlier one, because only an owner's answer to this gate counts" '[ "$(jira_run "$P/scripts/state.sh" get "$jira_gated" answer)" = "$jira_owner_answer" ]'
check_all "JiraAnsweredGate_SecondPassClearsNothing: a second answers pass on the cleared id prints nothing, because its record holds no gate" '[ -z "$(jira_run "$P/adapters/jira/answers.sh" "$jira_gated")" ]'
jira_run "$P/scripts/gate.sh" raise "$jira_gated" ambiguity "2. And now?" >/dev/null 2>&1
jira_comment_as "$jira_gated" stranger@acme.test "/answer"
jira_area_config '  answer_from: [stranger@acme.test]
'
check_all "JiraAnswerFromEmail_Counts: an /answer by an email in jira.answer_from clears the gate, because answer_from names who may answer" '[ "$(jira_run "$P/adapters/jira/answers.sh" "$jira_gated")" = "$jira_gated" ]'
check_all "JiraBareAnswer_TakesTheRecommendations: /answer alone records the answer as recommended, because a bare answer accepts the recommendations" '[ "$(jira_run "$P/scripts/state.sh" get "$jira_gated" answer)" = "as recommended" ]'
echo "jira tracker scope (fake curl)"
jira_set() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); f=d["issues"][sys.argv[2]]["fields"]
if sys.argv[3] == "labels": f["labels"] = [sys.argv[4]]
else: f["assignee"] = {"accountId": "acct-" + sys.argv[4], "emailAddress": sys.argv[4], "displayName": sys.argv[4]}
json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json" "${1#jira:}" "$2" "$3"; }
jira_area_config '  scope:
    labels: [team-a]
'
jsg_in="$(jira_run "$P/adapters/jira/create.sh" task "Scoped gate inside")"; jira_set "$jsg_in" labels team-a
jsg_out="$(jira_run "$P/adapters/jira/create.sh" task "Scoped gate outside")"; jira_set "$jsg_out" labels team-b
for gated in "$jsg_in" "$jsg_out"; do
  jira_run "$P/scripts/gate.sh" raise "$gated" ambiguity "1. Which way?" >/dev/null 2>&1
  jira_comment_as "$gated" flow@acme.test "/answer this way"
done
jira_run "$P/adapters/jira/answers.sh" "$jsg_in" "$jsg_out" >/dev/null 2>&1
check "JiraScopedAnswers_GateInside_IsCleared: answers clears an answered gate on an issue inside jira.scope, because answers reads the scoped issues" [ "$(jira_run "$P/scripts/state.sh" get "$jsg_in" gate)" = none ]
check "JiraScopedAnswers_GateOutside_IsLeft: answers leaves an answered gate on an issue outside jira.scope, because it reads only the scoped issues" [ "$(jira_run "$P/scripts/state.sh" get "$jsg_out" gate)" = ambiguity ]
jsp="$(jira_run "$P/adapters/jira/create.sh" epic "Scoped parent")"; jira_set "$jsp" labels team-a
jira_set "$(jira_run "$P/adapters/jira/create.sh" task "Child inside" --parent "$jsp")" labels team-a
jira_set "$(jira_run "$P/adapters/jira/create.sh" task "Child outside" --parent "$jsp")" labels team-b
children_inside=1
listed_children="$(jira_run "$P/adapters/jira/list.sh" | python3 -c 'import json,sys; print([i["open_children"] for i in json.load(sys.stdin) if i["id"] == sys.argv[1]])' "$jsp")"
check "JiraScopedList_CountsChildrenInside: list counts only the open children inside jira.scope, because the scope is ANDed into the children search" [ "$listed_children" = "[$children_inside]" ]
check "JiraScopedRead_CountsChildrenInside: read counts only the open children inside jira.scope, because the scope is ANDed into its children search" [ "$(jira_run "$P/adapters/jira/read.sh" "$jsp" | jget open_children)" = "$children_inside" ]
jira_area_config '  scope:
    kinds: [epic]
'
jke="$(jira_run "$P/adapters/jira/create.sh" epic "Epic with a task child")"
jira_run "$P/adapters/jira/create.sh" task "Task child outside the kinds" --parent "$jke" >/dev/null
kind_listed_children="$(jira_run "$P/adapters/jira/list.sh" | python3 -c 'import json,sys; print([i["open_children"] for i in json.load(sys.stdin) if i["id"] == sys.argv[1]])' "$jke")"
check "JiraKindScopedList_ChildOfOtherKind_NotCounted: list counts no open child of a kind outside jira.scope, because the scope's kinds bound the children too" [ "$kind_listed_children" = "[0]" ]
check "JiraKindScopedRead_ChildOfOtherKind_NotCounted: read counts no open child of a kind outside jira.scope, because the scope's kinds bound the children too" [ "$(jira_run "$P/adapters/jira/read.sh" "$jke" | jget open_children)" = 0 ]
jira_kind_ids() { jira_run "$P/adapters/jira/list.sh" | python3 -c 'import json,sys; print(" ".join(i["id"] for i in json.load(sys.stdin)))'; }
jira_labelled() { # jira_labelled <label> <create.sh args...>: a new issue carrying the label; prints its id
  jira_label="$1"; shift
  jira_new="$(jira_run "$P/adapters/jira/create.sh" "$@")"; jira_set "$jira_new" labels "$jira_label"; printf '%s' "$jira_new"
}
jira_area_config '  limit: 1
  scope:
    labels: [kind-limit-bug]
    kinds: [bug]
'
jkb="$(jira_labelled kind-limit-bug bug "Bug older than the tasks")"
jira_labelled kind-limit-bug task "Newer task" >/dev/null; jira_labelled kind-limit-bug task "Newest task" >/dev/null
check "JiraKindScopedList_NewerIssuesOfOtherKinds_ListsScopedPastThem: list keeps a bug past the newer tasks jira.limit 1 would hold, because the scope's kinds go into the search the limit counts" [ "$(jira_kind_ids)" = "$jkb" ]
jira_area_config '  limit: 1
  scope:
    labels: [kind-limit-task]
    kinds: [task]
'
jks="$(jira_labelled kind-limit-task task "Story older than the epic and the bug" --type Story)"
jira_labelled kind-limit-task epic "Newer epic" >/dev/null; jira_labelled kind-limit-task bug "Newest bug" >/dev/null
check "JiraTaskScopedList_NewerEpicAndBug_ListsStoryPastThem: list keeps a Story as a task past the newer epic and bug jira.limit 1 would hold, because every type but the epic and bug ones is a task in the search" [ "$(jira_kind_ids)" = "$jks" ]
jira_area_config '  scope:
    query: '"'"'labels = "team-a"'"'"'
pick:
  mine:
    query: assignee = currentUser()
    trackers: [jira]
'
jq_both="$(jira_run "$P/adapters/jira/create.sh" task "Scope and pick")"; jira_set "$jq_both" labels team-a; jira_set "$jq_both" assignee flow@acme.test
jq_scope="$(jira_run "$P/adapters/jira/create.sh" task "Scope only")"; jira_set "$jq_scope" labels team-a
jq_pick="$(jira_run "$P/adapters/jira/create.sh" task "Pick only")"; jira_set "$jq_pick" labels team-b; jira_set "$jq_pick" assignee flow@acme.test
jira_query_ids="$(jira_run "$P/adapters/jira/list.sh" --pick mine | python3 -c 'import json,sys; print(" ".join(i["id"] for i in json.load(sys.stdin)))')"
check_all "JiraScopeQueryAndPickQuery_KeepsIssueBothMatch: the list keeps the issue the scope and the pick both match, because the scope and the pick compose" 'case " $jira_query_ids " in *" $jq_both "*) true ;; *) false ;; esac'
check_all "JiraScopeQueryAndPickQuery_DropsScopeOnly: the list leaves out an issue only the scope matches, because the pick applies too" '[ -n "$jira_query_ids" ] && case " $jira_query_ids " in *" $jq_scope "*) false ;; *) true ;; esac'
check_all "JiraScopeQueryAndPickQuery_DropsPickOnly: the list leaves out an issue only the pick matches, because the scope applies too" '[ -n "$jira_query_ids" ] && case " $jira_query_ids " in *" $jq_pick "*) false ;; *) true ;; esac'
echo "jira set-status and assign (fake curl)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
d["transitions"] = [{"id": "21", "name": "In Progress", "category": "indeterminate"}, {"id": "12", "name": "Selected for Development", "category": "new"},
  {"id": "11", "name": "To Do", "category": "new"}, {"id": "61", "name": "Code Review", "category": "indeterminate"}, {"id": "31", "name": "Done", "category": "done"}]
json.dump(d, open(sys.argv[1], "w"))' "$work/jira/jira.json"
jira_config https://acme.atlassian.net
printf '    in-review: Code Review\n    backlog: Parked\n' >> .flow/config.yaml
jira_status_name() { jira_db "d[\"issues\"][\"${1#jira:}\"][\"fields\"][\"status\"][\"name\"]"; }
jira_named="$(jira_run "$P/adapters/jira/create.sh" task "Moved by a named transition")"
jira_run "$P/adapters/jira/set-status.sh" "$jira_named" in-review >/dev/null 2>&1
check "JiraSetStatusNamedTransition_TakesIt: set-status in-review lands on the status jira.transitions.in-review names, because a named transition wins over the category" [ "$(jira_status_name "$jira_named")" = "Code Review" ]
check "JiraSetStatusNamedTransitionMissing_ExitsOne: set-status backlog exits 1 when the issue has no transition jira.transitions.backlog names, because the setting points nowhere" [ "$(jira_run "$P/adapters/jira/set-status.sh" "$jira_named" backlog >/dev/null 2>&1; echo $?)" = 1 ]
jira_fallback="$(jira_run "$P/adapters/jira/create.sh" task "Moved by its category")"
jira_run "$P/adapters/jira/set-status.sh" "$jira_fallback" in-progress >/dev/null 2>&1
check "JiraSetStatusInProgressUnset_TakesFirstIndeterminate: set-status in-progress with no jira.transitions.in-progress takes the first transition into indeterminate, because that category is in progress" [ "$(jira_status_name "$jira_fallback")" = "In Progress" ]
jira_run "$P/adapters/jira/set-status.sh" "$jira_fallback" ready >/dev/null 2>&1
check "JiraSetStatusReadyUnset_TakesFirstNew: set-status ready with no jira.transitions.ready takes the first transition into new, because that category is to do" [ "$(jira_status_name "$jira_fallback")" = "Selected for Development" ]
jira_unplaced="$(jira_run "$P/adapters/jira/create.sh" task "No place for needs-you")"
jira_run "$P/adapters/jira/set-status.sh" "$jira_unplaced" needs-you >/dev/null 2>&1
jira_run "$P/adapters/jira/set-status.sh" "$jira_unplaced" needs-you >/dev/null 2>&1; jira_unplaced_code=$?
check "JiraSetStatusNoTransition_ExitsZero: set-status needs-you with no jira.transitions.needs-you exits 0, because a status the tracker has no place for is no failure" [ "$jira_unplaced_code" = 0 ]
check "JiraSetStatusNoTransition_SaidOnce: two set-status needs-you with no transition leave one events.log line, because the owner needs telling once, not on every gate" [ "$(grep -c "no transition for needs-you: set jira.transitions.needs-you" "$(flow_home)/events.log")" = 1 ]
echo "jira set-status through a transition named apart from the status it leads to"
jira_review_transition="Submit for review"; jira_review_status="In Review"
python3 -c 'import json,sys; jira_data=json.load(open(sys.argv[1]))
jira_data["transitions"].append({"id": "71", "name": sys.argv[2], "to": sys.argv[3], "category": "indeterminate", "from": ["To Do", "In Progress"]})
json.dump(jira_data, open(sys.argv[1], "w"))' "$work/jira/jira.json" "$jira_review_transition" "$jira_review_status"
jira_config https://acme.atlassian.net
printf '    in-review: %s\n' "$jira_review_transition" >> .flow/config.yaml
jira_submitted="$(jira_run "$P/adapters/jira/create.sh" task "Submitted for review")"
jira_run "$P/adapters/jira/set-status.sh" "$jira_submitted" in-review >/dev/null 2>&1
check "JiraSetStatusTransitionNamedApart_LandsOnItsTarget: set-status in-review lands on the status the jira.transitions.in-review transition leads to, because a transition's name need not be its status's" [ "$(jira_status_name "$jira_submitted")" = "$jira_review_status" ]
jira_run "$P/adapters/jira/set-status.sh" "$jira_submitted" in-review > "$work/jira/resubmitted.out" 2>/dev/null; jira_resubmitted_code=$?
check "JiraSetStatusTransitionNamedApartRepeated_ExitsZero: a second set-status in-review exits 0 though Jira lists no transition of that name out of the status it led to, because the issue is there already" [ "$jira_resubmitted_code" = 0 ]
check "JiraSetStatusTransitionNamedApartRepeated_PrintsNothing: a second set-status in-review prints nothing, because the issue did not move" [ ! -s "$work/jira/resubmitted.out" ]
check "JiraSetStatusTransitionNamedApartRepeated_StaysInItsStatus: a second set-status in-review leaves the issue in the status the transition led to, because a push repeats on every step" [ "$(jira_status_name "$jira_submitted")" = "$jira_review_status" ]
jira_assigned="$(jira_run "$P/adapters/jira/create.sh" task "Assigned to me")"
jira_run "$P/adapters/jira/assign.sh" "$jira_assigned" me >/dev/null 2>&1
check "JiraAssignMe_AssigneesHoldTokenUser: after assign me the issue's assignees hold the token's user, because me is the account the token belongs to" [ "$(jira_run "$P/adapters/jira/read.sh" "$jira_assigned" | jget assignees)" = '["flow@acme.test"]' ]
jira_run "$P/adapters/jira/assign.sh" "$jira_assigned" none >/dev/null 2>&1
check "JiraAssignNone_ClearsAssignee: after assign none the issue has no assignee, because the token's user held it" [ "$(jira_run "$P/adapters/jira/read.sh" "$jira_assigned" | jget assignees)" = "[]" ]
jira_theirs="$(jira_run "$P/adapters/jira/create.sh" task "Assigned to someone else")"; jira_set "$jira_theirs" assignee someone@acme.test
jira_run "$P/adapters/jira/assign.sh" "$jira_theirs" me >/dev/null 2>&1
check "JiraAssignMeOnOthersIssue_KeepsTheirs: assign me leaves an issue someone else holds with them, because Jira holds one assignee and the flow never takes it" [ "$(jira_run "$P/adapters/jira/read.sh" "$jira_theirs" | jget assignees)" = '["someone@acme.test"]' ]
cp "$work/config.gh" .flow/config.yaml

[ "$fails" -eq 0 ] && { echo "jira-adapter: ok"; exit 0; }
echo "jira-adapter: $fails failed"; exit 1
