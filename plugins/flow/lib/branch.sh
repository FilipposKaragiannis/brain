# The task branch of an item: named once, when the item is first claimed, from the branch template
# of .flow/config.yaml, and recorded in claim.json and the item state (branch). Every reader takes
# it from there. Sourced after lib/flow.sh and lib/base.sh by scripts/steward.sh, scripts/next.sh
# and hooks/worktree-create.sh (claim_at_base picks the branch from the item it read).
#
# branch: one template, or one per kind (epic, task, bug). Its placeholders: {slug} (item_slug),
# {key} (branch_key), {kind} and {title} (branch_title).

branch_default_template='flow/{slug}'

# The most characters {title} keeps of a title.
branch_title_length_cap=40

# Why a claim refuses a task branch name. The name stays out: the template is free text.
branch_name_refused='the branch template gives no valid branch name for its task branch'
branch_unread_refused='the branch template needs the item, which could not be read'

# branch_template <kind>: the template for a kind: branch.<kind>, else a scalar branch, else
# flow/{slug}. A per-kind map that leaves the kind out gives flow/{slug}; with no kind (the item
# could not be read) a per-kind map gives nothing.
branch_template() {
  if [ -n "$(yaml_keys "$(config_file)" branch)" ]; then
    [ -n "$1" ] || return 0
    cfg_or "branch.$1" "$branch_default_template"
    return
  fi
  cfg_or branch "$branch_default_template"
}

# branch_key <id>: the id past its tracker prefix, / as -, lower-cased: gh#73 gives 73,
# jira:PROJ-123 proj-123, local:task/3 task-3.
branch_key() { printf '%s' "${1#*[#:]}" | LC_ALL=C tr 'A-Z/' 'a-z-'; }

# branch_title <title>: the title folded to ASCII, lower-cased, each run of other characters as one
# -, trimmed of -, cut to branch_title_length_cap characters and trimmed of - again.
branch_title() {
  python3 -I -c '
import re, sys, unicodedata
folded = unicodedata.normalize("NFKD", sys.argv[1]).encode("ascii", "ignore").decode("ascii").lower()
hyphenated = re.sub("[^a-z0-9]+", "-", folded).strip("-")
print(hyphenated[:int(sys.argv[2])].strip("-"), end="")' "$1" "$branch_title_length_cap"
}

# branch_substituted <text> <placeholder> <value>: the text with every placeholder replaced.
branch_substituted() {
  substituted_head=""; substituted_rest="$1"
  while :; do
    case "$substituted_rest" in *"$2"*) ;; *) break ;; esac
    substituted_head="$substituted_head${substituted_rest%%"$2"*}$3"; substituted_rest="${substituted_rest#*"$2"}"
  done
  printf '%s%s' "$substituted_head" "$substituted_rest"
}

# branch_render <template> <id> <kind> <title>: the template with {slug}, {key}, {kind} and {title}
# filled in for the item, less any trailing -.
branch_render() {
  rendered="$(branch_substituted "$1" '{slug}' "$(item_slug "$2")")"
  rendered="$(branch_substituted "$rendered" '{key}' "$(branch_key "$2")")"
  rendered="$(branch_substituted "$rendered" '{kind}' "$3")"
  rendered="$(branch_substituted "$rendered" '{title}' "$(branch_title "$4")")"
  while :; do case "$rendered" in *-) rendered="${rendered%-}" ;; *) break ;; esac; done
  printf '%s' "$rendered"
}

# branch_name_valid <name>: true for a name git takes as a branch (check-ref-format --branch) that
# base_name_valid also takes, so a child can start from it through claim_name.
branch_name_valid() {
  base_name_valid "$1" && git -C "$(flow_repository)" check-ref-format --branch "$1" >/dev/null 2>&1
}

# claim_branch <item> <item-json>: the task branch a new claim of the item takes. The branch its
# state records (a release keeps it, and a title edit never renames it); else flow/<slug> when that
# branch exists (a claim made before the template); else the item's template rendered. With no
# item JSON (the item could not be read) it renders from the id alone, and gives nothing and 1 when
# the template needs the kind or the title, or is a per-kind map.
claim_branch() {
  claimed_item_json="$2"
  recorded_branch="$(state_get "$claimed_item_json" branch)"
  if [ -n "$recorded_branch" ]; then printf '%s' "$recorded_branch"; return; fi
  legacy_branch="flow/$(item_slug "$1")"
  if git -C "$(flow_repository)" show-ref --verify --quiet "refs/heads/$legacy_branch"; then printf '%s' "$legacy_branch"; return; fi
  claimed_kind="$(json_get "$claimed_item_json" kind)"
  claimed_template="$(branch_template "$claimed_kind")"
  if [ -z "$claimed_kind" ]; then case "$claimed_template" in ''|*'{kind}'*|*'{title}'*) return 1 ;; esac; fi
  branch_render "$claimed_template" "$1" "$claimed_kind" "$(json_get "$claimed_item_json" title)"
}

# claim_branch_option [--base <branch>] [--branch <name>]: the name --branch gives, or nothing.
# claim_base_option refuses a malformed option first.
claim_branch_option() {
  while [ $# -ge 2 ]; do case "$1" in --branch) printf '%s' "$2"; return ;; *) shift ;; esac; done
}

# refuse_claim <item> <why> <code>: ends a claim before it creates anything: why goes to the item's
# last_event and to stderr, the code is the exit code (2 a name the config cannot give, 4 a name
# another claim holds).
refuse_claim() {
  adapter write-state "$1" "last_event=$(now_iso) $2" >/dev/null 2>&1
  die "$1: $2" "$3"
}
