#!/bin/sh
# github me: the login of the gh user, the one name `me` stands for in a pick, github.scope or
# ready.assignee.
set -u
. "$(dirname "$0")/_gh.sh"
[ $# -eq 0 ] || die "usage: me" "$EXIT_USAGE"
login="$(gh api user -q .login)" && [ -n "$login" ] \
  || die "cannot read the gh user that me stands for; log in with gh auth login"
printf '%s\n' "$login"
