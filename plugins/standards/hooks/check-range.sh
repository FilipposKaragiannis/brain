#!/bin/sh
# Run the commit gates over every non-merge commit in <base>..<head>, each against its own message,
# so a marker ([config], [allow-docs], [why-comment], a gate's marker) counts for the commit that
# carries it and no other. CI calls it (the plugin's composite action, action/action.yml);
# locally: .standards/hooks/check-range.sh origin/main HEAD
#   check-range.sh [--gates "check-config check-comments check-gates"] <base> [head]
# It checks each commit out in turn, so it refuses to run over uncommitted tracked changes, and it
# returns the checkout to where it started. Commits without .standards/config.json are skipped.
# check-gates runs with STANDARDS_STAGE=ci: only the command gates that list "ci". Exit 1 when
# any commit fails, 2 on a usage or checkout problem.
set -u
gates="check-config check-comments check-gates"
usage() { echo "usage: $0 [--gates \"check-config check-comments check-gates\"] <base> [head]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in --gates) gates="$2"; shift 2 ;; -*) usage ;; *) break ;; esac
done
[ $# -ge 1 ] || usage
base="$1"; head="${2:-HEAD}"
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
cd "$(repo_root)" || exit 2
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "check-range: commit or stash the tracked changes first; this script checks commits out." >&2
  exit 2
fi
start="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
scratch="$(mktemp -d 2>/dev/null || { d="${TMPDIR:-/tmp}/standards-range-$$"; mkdir -p "$d" && echo "$d"; })"
[ -d "$scratch" ] || { echo "check-range: cannot create a scratch directory" >&2; exit 2; }
cp -R "$here" "$scratch/hooks"   # the scripts stay put while the commits are checked out
trap 'git checkout -q -f "$start"; rm -rf "$scratch"' EXIT
failed=0; checked=0
for commit in $(git rev-list --reverse --no-merges "$base..$head"); do
  git rev-parse -q --verify "$commit^" >/dev/null 2>&1 || continue
  git checkout -q -f "$commit" || exit 2
  [ -f .standards/config.json ] || continue
  git reset -q --soft "$commit^"
  git log -1 --format=%B "$commit" > "$scratch/msg"
  payload="$(printf '{"tool_input":{"command":%s}}' "$(json_string "git commit -F \"$scratch/msg\"")")"
  checked=$((checked + 1))
  for gate in $gates; do
    printf '%s' "$payload" | STANDARDS_STAGE=ci "$scratch/hooks/$gate.sh" || { echo "  in commit $(git log -1 --format='%h %s' "$commit")" >&2; failed=1; }
  done
done
echo "check-range: $checked commit(s) checked in $base..$head"
exit "$failed"
