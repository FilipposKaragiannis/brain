# The task branch of an item: named once, when the item is first claimed, from the branch template
# of .flow/config.yaml, and recorded in claim.json and the item state (branch). Every reader takes
# it from there. Sourced after lib/flow.sh and lib/base.sh by scripts/steward.sh, scripts/next.sh
# and hooks/worktree-create.sh (claim_at_base picks the branch from the item it read), after
# lib/flow.sh alone by scripts/comments.sh and jobs/comments.sh (branch_item), and after lib/flow.sh
# and lib/base.sh by skills/init/scripts/init.sh (branch_problems).
#
# branch: one template, or one per kind (epic, task, bug). Its placeholders: {slug} (item_slug),
# {key} (branch_key), {kind} and {title} (branch_title).

branch_default_template='flow/{slug}'

# The kinds branch: takes a template for, and the placeholders a template takes.
branch_kinds='epic task bug'
branch_placeholders='{slug} {key} {kind} {title}'

# The item init renders a template for when it checks the name: local:<kind>/<number>.
branch_sample_number=1
branch_sample_title='A sample title'

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

# claim_branch <item> <item-json> <base>: the task branch a new claim of the item from the base
# takes. The branch its state records when branch_recorded_trusted takes it (a release keeps it,
# and a title edit never renames it); else flow/<slug> when that branch exists (a claim made before
# the template); else the item's template rendered. With no item JSON (the item could not be read)
# it renders from the id alone, and gives nothing and 1 when the template needs the kind or the
# title, or is a per-kind map.
claim_branch() {
  claimed_item_json="$2"
  claimed_kind="$(json_get "$claimed_item_json" kind)"
  recorded_branch="$(state_get "$claimed_item_json" branch)"
  if [ -n "$recorded_branch" ] && branch_recorded_trusted "$recorded_branch" "$1" "$claimed_kind" "$3"; then printf '%s' "$recorded_branch"; return; fi
  legacy_branch="flow/$(item_slug "$1")"
  if git -C "$(flow_repository)" show-ref --verify --quiet "refs/heads/$legacy_branch"; then printf '%s' "$legacy_branch"; return; fi
  claimed_template="$(branch_template "$claimed_kind")"
  if [ -z "$claimed_kind" ]; then case "$claimed_template" in ''|*'{kind}'*|*'{title}'*) return 1 ;; esac; fi
  branch_render "$claimed_template" "$1" "$claimed_kind" "$(json_get "$claimed_item_json" title)"
}

# branch_recorded_trusted <branch> <item> <kind> <base>: true when the flow could have named the
# branch for the item: flow/<slug>, or the kind's template with any title. Never the claim base,
# the config base or origin's default branch. The item state is tracker text anyone may write.
branch_recorded_trusted() {
  case "$1" in "$4"|"$(cfg_or base main)"|"$(branch_remote_default)") return 1 ;; esac
  [ "$1" != "flow/$(item_slug "$2")" ] || return 0
  branch_fits_template "$1" "$(branch_template "$3")" "$(item_slug "$2")" "$(branch_key "$2")" "$3"
}

# branch_remote_default: the branch origin/HEAD points at, or nothing.
branch_remote_default() {
  remote_head="$(git -C "$(flow_repository)" symbolic-ref --short -q refs/remotes/origin/HEAD)"
  [ -z "$remote_head" ] || printf '%s' "${remote_head#origin/}"
}

# branch_fits_template <branch> <template> <slug> <key> <kind>: true when branch_render gives the
# branch for some title: {slug}, {key} and {kind} exact, {title} any run of a-z, 0-9 and - up to
# branch_title_length_cap, the rest literal.
branch_fits_template() {
  [ -n "$2" ] || return 1
  python3 -I -c '
import re, sys
branch, template, cap = sys.argv[1], sys.argv[2], int(sys.argv[6])
exact_placeholders = list(zip(("{slug}", "{key}", "{kind}"), sys.argv[3:6]))
def filled(part):
    for placeholder, value in exact_placeholders: part = part.replace(placeholder, value)
    return re.escape(part)
pattern = ("[a-z0-9-]{0,%d}" % cap).join(filled(part) for part in template.split("{title}"))
untrimmed = (branch + "-" * dashes for dashes in range(len(template) + 1))
sys.exit(0 if not branch.endswith("-") and any(re.fullmatch(pattern, name) for name in untrimmed) else 1)' \
    "$1" "$2" "$3" "$4" "$5" "$branch_title_length_cap"
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

# branch_item <branch>: the item whose task branch it is: the tracker item whose pool claim holds it
# (steward.sh owner), else for flow/<slug> the item the slug names (its claim released); nothing
# for a branch the flow did not name.
branch_item() {
  [ -n "$1" ] || return 0
  owning_item="$("$FLOW_PLUGIN/scripts/steward.sh" owner "$1" 2>/dev/null)"
  if [ -n "$owning_item" ] && adapter_for "$owning_item" >/dev/null; then printf '%s' "$owning_item"; return; fi
  case "$1" in flow/?*) slug_item "${1#flow/}" ;; esac
}

# branch_problems: one line per problem with the branch config of .flow/config.yaml, for init: a
# key under branch: that names no kind, then the problems of each template.
branch_problems() {
  configured_kinds="$(yaml_keys "$(config_file)" branch)"
  if [ -z "$configured_kinds" ]; then
    branch_template_problems branch task "$(cfg branch)"
    return 0
  fi
  printf '%s\n' "$configured_kinds" | while IFS= read -r configured_kind; do
    case " $branch_kinds " in
      *" $configured_kind "*) branch_template_problems "branch.$configured_kind" "$configured_kind" "$(cfg "branch.$configured_kind")" ;;
      *) printf 'branch.%s names no kind; branch takes a template for each of %s\n' "$configured_kind" "$branch_kinds" ;;
    esac
  done
}

# branch_template_problems <key> <kind> <template>: one line per problem with the template under
# the key: each placeholder it does not take; neither {key} nor {slug}, so two items would share a
# branch; and, when it takes every placeholder, a name for a sample item of the kind that
# branch_name_valid refuses. An empty template is flow/{slug}, which has none.
branch_template_problems() {
  [ -n "$3" ] || return 0
  unknown_placeholders="$(branch_unknown_placeholders "$3")"
  printf '%s\n' "$unknown_placeholders" | while IFS= read -r unknown_placeholder; do
    [ -z "$unknown_placeholder" ] || printf '%s is %s; %s is not a placeholder, it takes %s\n' "$1" "$3" "$unknown_placeholder" "$branch_placeholders"
  done
  case "$3" in *'{key}'*|*'{slug}'*) ;; *) printf '%s is %s; it has neither {key} nor {slug}, so two items would share one branch\n' "$1" "$3" ;; esac
  [ -z "$unknown_placeholders" ] || return 0
  sample_branch="$(branch_render "$3" "local:$2/$branch_sample_number" "$2" "$branch_sample_title")"
  branch_name_valid "$sample_branch" || printf '%s is %s; it gives %s, not a valid branch name\n' "$1" "$3" "$sample_branch"
}

# branch_unknown_placeholders <template>: each {...} in the template that branch_placeholders leaves
# out, once, one per line.
branch_unknown_placeholders() {
  printf '%s\n' "$1" | awk -v known=" $branch_placeholders " '{
    while (match($0, /[{][^{}]*[}]/)) {
      placeholder = substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH)
      if (index(known, " " placeholder " ") == 0 && !(placeholder in seen)) { seen[placeholder] = 1; print placeholder }
    }
  }'
}
