#!/bin/sh
# github write-state <id> key=value...: labels for step, gate, worktree (wt:), profile (flow:)
# and size (the github.fields.size issue field instead, when set); the full state in the marked
# comment; then the project card's Status. Lists are comma-separated.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: write-state <id> key=value..." 2
repo="$(gh_repo)"; n="$(issue_number "$1")"; shift
current="$(state_comment "$repo" "$n")"
labels="$(gh issue view "$n" -R "$repo" --json labels -q '.labels[].name')"
merged="$(printf '%s' "$current" | python3 -I -c '
import json, sys
data = json.load(sys.stdin)["data"]
for kv in sys.argv[1:]:
    k, v = kv.split("=", 1); k = k.replace("-", "_")
    if k == "touches": data[k] = [x for x in v.split(",") if x.strip()]
    elif k == "attempts": data[k] = int(v or 0)
    else: data[k] = v
data.setdefault("gate", "none")
print(json.dumps(data))' "$@")"
add=""; remove=""
label_keys="step gate worktree profile size"
[ -n "$GH_SIZE_FIELD" ] && label_keys="step gate worktree profile"
for key in $label_keys; do
  case "$key" in step) prefix="step:" ;; gate) prefix="gate:" ;; worktree) prefix="wt:" ;; profile) prefix="flow:" ;; size) prefix="size:" ;; esac
  for kv in "$@"; do
    [ "${kv%%=*}" = "$key" ] || continue
    value="${kv#*=}"
    for old in $(printf '%s\n' "$labels" | grep "^$prefix" || true); do
      [ "$old" = "$prefix$value" ] || remove="$remove --remove-label $old"
    done
    if [ -n "$value" ] && [ "$value" != "none" ]; then ensure_label "$prefix$value"; add="$add --add-label $prefix$value"; fi
  done
done
# shellcheck disable=SC2086
[ -n "$add$remove" ] && gh issue edit "$n" -R "$repo" $add $remove >/dev/null
body="$(printf '%s\nFlow state, written by the flow plugin. Do not edit by hand.\n\n```json\n%s\n```\n' "$STATE_MARKER" "$(printf '%s' "$merged" | python3 -I -c 'import json,sys; print(json.dumps(json.load(sys.stdin), indent=2, sort_keys=True))')")"
cid="$(printf '%s' "$current" | python3 -I -c 'import json,sys; v=json.load(sys.stdin)["id"]; print(v if v else "")')"
if [ -n "$cid" ]; then
  printf '%s' "$body" | gh api -X PATCH "repos/$repo/issues/comments/$cid" -F body=@- >/dev/null
else
  printf '%s' "$body" | gh api "repos/$repo/issues/$n/comments" -F body=@- >/dev/null
fi
if [ -n "$GH_SIZE_FIELD" ]; then
  for kv in "$@"; do
    case "$kv" in size=?*) python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" field "$repo" "$n" "$GH_SIZE_FIELD" "${kv#size=}" \
      || echo "flow: could not set the size of gh#$n" >&2 ;; esac
  done
fi
[ -n "$GH_PROJECT" ] && { "$FLOW_PLUGIN/adapters/github/sync.sh" "gh#$n" >/dev/null || echo "flow: could not move the project card of gh#$n" >&2; }
exit 0
