# _jobs_fixture.sh: the fake hosts the jobs run on: claude and codex in $work/bin logging to HOST_LOG, the
# repo's real path, the polls the job checks wait with, a comments job that only sleeps in
# $work/fake/jobs, and a second flow home. Takes $work and $repo. Sourced after
# _github_fixture.sh, never run.
export HOST_LOG="$work/host.log"; realrepo="$(cd "$repo" && pwd -P)"
for h in claude codex; do printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/$h"; chmod +x "$work/bin/$h"; done
mark_comments_log() { comments_log_mark="$(wc -l < .flow/log/comments.log | tr -d ' ')"; }
comments_logged_since_mark() { tail -n "+$((comments_log_mark + 1))" .flow/log/comments.log | grep -q "$1"; }
POLL_LIMIT=150
wait_for() { # wait_for <condition...>: polls up to 15 s
  poll_count=0; while ! "$@" 2>/dev/null && [ "$poll_count" -lt "$POLL_LIMIT" ]; do sleep 0.1; poll_count=$((poll_count + 1)); done
}
mkdir -p "$work/fake/jobs" && printf '#!/bin/sh\nsleep 60 &\nwait\n' > "$work/fake/jobs/comments.sh" && chmod +x "$work/fake/jobs/comments.sh"
home2="$work/home2"; mkdir -p "$home2"
