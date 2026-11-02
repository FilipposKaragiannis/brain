#!/bin/sh
# Shared pieces of the Jira adapter: the checks that stop a call before it starts, and the settings
# _jira.py reads (FLOW_JIRA_*). Jira Cloud REST API v3 through curl. The API token comes from the
# environment (JIRA_API_TOKEN) only, never from the config, and goes to curl on its stdin.
. "$(dirname "$0")/../../lib/flow.sh"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
[ -n "${JIRA_API_TOKEN:-}" ] || die "JIRA_API_TOKEN is not set: the Jira adapter takes its API token from the environment only, never from .flow/config.yaml"
FLOW_JIRA_SITE="$(cfg jira.site)"; FLOW_JIRA_PROJECT="$(cfg jira.project)"; FLOW_JIRA_EMAIL="$(cfg jira.email)"
[ -n "$FLOW_JIRA_PROJECT" ] || die "jira.project is not set in .flow/config.yaml: the key of the project the flow reads"
[ -n "$FLOW_JIRA_EMAIL" ] || die "jira.email is not set in .flow/config.yaml: the login the API token belongs to"
case "$FLOW_JIRA_SITE" in https://?*) ;; *) die "jira.site in .flow/config.yaml must be the https:// address of the site (https://<org>.atlassian.net), not '$FLOW_JIRA_SITE'" ;; esac
FLOW_JIRA_TYPE_EPIC="$(cfg jira.types.epic)"; FLOW_JIRA_TYPE_TASK="$(cfg jira.types.task)"; FLOW_JIRA_TYPE_BUG="$(cfg jira.types.bug)"
FLOW_JIRA_SIZE_FIELD="$(cfg jira.fields.size)"; FLOW_JIRA_AREA_FIELD="$(cfg jira.fields.area)"
FLOW_JIRA_DONE="$(cfg jira.transitions.done)"; FLOW_JIRA_LIMIT="$(cfg jira.limit)"
FLOW_JIRA_ANSWER_FROM="$(cfg jira.answer_from | paste -sd, -)"
export FLOW_JIRA_SITE FLOW_JIRA_PROJECT FLOW_JIRA_EMAIL FLOW_JIRA_TYPE_EPIC FLOW_JIRA_TYPE_TASK FLOW_JIRA_TYPE_BUG \
  FLOW_JIRA_SIZE_FIELD FLOW_JIRA_AREA_FIELD FLOW_JIRA_DONE FLOW_JIRA_LIMIT FLOW_JIRA_ANSWER_FROM
# ready_rules is lib/flow.sh's once it reads ready.* for every tracker; until then the same two keys.
command -v ready_rules >/dev/null 2>&1 || ready_rules() {
  READY_NEEDS="$(cfg ready.needs | paste -sd, -)"; READY_PRIORITY_ORDER="$(cfg ready.priority_order | paste -sd, -)"
  export READY_NEEDS READY_PRIORITY_ORDER
}
jira() { python3 -I "$FLOW_PLUGIN/adapters/jira/_jira.py" "$@"; }
