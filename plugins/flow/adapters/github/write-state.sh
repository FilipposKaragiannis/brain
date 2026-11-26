#!/bin/sh
# github write-state <id> key=value...: labels for step, gate, worktree (wt:), profile (flow:)
# and size (the github.fields.size issue field instead, when set); the full state in the marked
# comment. Lists are comma-separated.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: write-state <id> key=value..." 2
repo="$(gh_repo)"; n="$(issue_number "$1")" || exit 2; shift
# The state keys of adapters/README.md; any other is refused before anything is written.
for kv in "$@"; do
  case "$kv" in *=*) ;; *) die "expected key=value, got $kv" 2 ;; esac
  case "$(printf '%s' "${kv%%=*}" | tr - _)" in
    step|profile|size|worktree|attempts|gate|gate_from|last_event|pr|pr_host|touches|changes|held_by|held_reason|answered|asked|answer|answered_at|answer_pending|base|branch) ;;
    *) die "unknown state key ${kv%%=*}" 2 ;;
  esac
done
# Every GitHub call here must land or the write stops and says so (the labels go first, the
# comment second, so a stop between them leaves new labels over the older comment, and labels win
# in issue_to_item). The callers in advance.sh and next.sh go on either way, with that state.
state_authors="$(trusted_logins)" || die "cannot tell whose state comments count on gh#$n (set github.answer_from, or log in with gh auth login)"
current="$(state_comment "$repo" "$n" "$state_authors")" || die "cannot read the comments of gh#$n"
comment_id() { cached_python3 -I -c 'import json,sys; found_id=json.load(sys.stdin)["id"]; print(found_id if found_id else "")'; }
state_comment_id="$(printf '%s' "$current" | comment_id)"
# A comment the gh user posts outside github.answer_from would be ignored on read, and every
# write would post one more; refused before the labels, so nothing is half written.
if [ -z "$state_comment_id" ] && [ -n "$(cfg github.answer_from)" ]; then
  state_poster="$("$FLOW_PLUGIN/adapters/github/me.sh")" || exit 1
  case ",$state_authors," in
    *",$state_poster,"*) ;;
    *) die "gh#$n has no state comment by a login in github.answer_from, and the gh user $state_poster is not one: add $state_poster to github.answer_from" ;;
  esac
fi
labels="$(gh issue view "$n" -R "$repo" --json labels -q '.labels[].name')" || die "cannot read the labels of gh#$n"
merged="$(printf '%s' "$current" | cached_python3 -I -c '
import json, sys
data = json.load(sys.stdin)["data"]
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1); k = k.replace("-", "_")
    if k in ("touches", "changes"): data[k] = [x for x in v.split(",") if x.strip()]
    elif k == "attempts": data[k] = int(v or 0)
    else: data[k] = v
data.setdefault("gate", "none")
print(json.dumps(data))' "$@")"
add_labels=""; remove_labels=""; line_break='
'
stale_labels() {
  label_prefix="$1"; kept_value="$2"
  while IFS= read -r old; do
    case "$old" in "$label_prefix"*) ;; *) continue ;; esac
    [ "$old" != "$label_prefix$kept_value" ] || continue
    case "$old" in *,*) echo "flow: left the label '$old' on gh#$n: a comma in it would make gh remove two" >&2; continue ;; esac
    printf '%s\n' "$old"
  done <<LABELS
$labels
LABELS
}
label_keys="step gate worktree profile size"
[ -n "$GH_SIZE_FIELD" ] && label_keys="step gate worktree profile"
for key in $label_keys; do
  case "$key" in step) prefix="step:" ;; gate) prefix="gate:" ;; worktree) prefix="wt:" ;; profile) prefix="flow:" ;; size) prefix="size:" ;; esac
  for kv in "$@"; do
    [ "${kv%%=*}" = "$key" ] || continue
    value="${kv#*=}"
    case "$value" in *"$line_break"*|*,*) die "the $key of gh#$n has a line break or a comma, so it cannot be a label" 2 ;; esac
    remove_labels="$remove_labels$line_break$(stale_labels "$prefix" "$value")"
    if [ -n "$value" ] && [ "$value" != "none" ]; then ensure_label "$prefix$value"; add_labels="$add_labels$line_break$prefix$value"; fi
  done
done
edit_labels() {
  set --
  while IFS= read -r label; do [ -z "$label" ] || set -- "$@" --add-label "$label"; done <<ADD
$add_labels
ADD
  while IFS= read -r label; do [ -z "$label" ] || set -- "$@" --remove-label "$label"; done <<REMOVE
$remove_labels
REMOVE
  [ $# -eq 0 ] || gh issue edit "$n" -R "$repo" "$@" >/dev/null
}
edit_labels || die "cannot write the labels of gh#$n"
body="$(printf '%s\nFlow state, written by the flow plugin. Do not edit by hand.\n\n```json\n%s\n```\n' "$STATE_MARKER" "$(printf '%s' "$merged" | cached_python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, sort_keys=True))')")"
patch_state() { printf '%s' "$body" | gh api -X PATCH "repos/$repo/issues/comments/$1" -F body=@- >/dev/null; }
post_state() { printf '%s' "$body" | gh_once api "repos/$repo/issues/$n/comments" -F body=@- >/dev/null; }
# The first state comment is a create: the answer can be lost after the comment landed, and a
# plain second try would make a second comment. So after a failed post, look; patch what landed,
# post once more when nothing did, and stop after that.
posts=0
while [ -z "$state_comment_id" ] && ! post_state; do
  posts=$((posts + 1))
  found="$(state_comment "$repo" "$n" "$state_authors")" || die "cannot write the state of gh#$n"
  state_comment_id="$(printf '%s' "$found" | comment_id)"
  [ -n "$state_comment_id" ] || [ "$posts" -lt 2 ] || die "cannot write the state of gh#$n"
done
if [ -n "$state_comment_id" ]; then patch_state "$state_comment_id" || die "cannot write the state of gh#$n"; fi
if [ -n "$GH_SIZE_FIELD" ]; then
  for kv in "$@"; do
    case "$kv" in size=?*) cached_python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" field "$repo" "$n" "$GH_SIZE_FIELD" "${kv#size=}" \
      || echo "flow: could not set the size of gh#$n" >&2 ;; esac
  done
fi
exit 0
