# _base_fixture.sh: the fixture base-readers.sh, base-claim.sh, verify-detached.sh and
# verify-ends.sh source: a work folder (each suite then puts it in tools/lib/sandbox.sh, which
# removes it on exit), an offline PATH, the check helpers, the names no claim may record, and
# new_repo, a clone of a fresh bare origin on the local adapter.
# Sourced, never run.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$plugin"
work="$(mktemp -d)"
unset FLOW_SLACK_WEBHOOK FLOW_HOME
mkdir -p "$work/home" "$work/offline" && HOME="$work/home" && export HOME && unset CODEX_HOME
for tool in curl wget gh osascript notify-send claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
export FLOW_HEALTH_PROCS="$work/procs"; : > "$FLOW_HEALTH_PROCS"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> '<condition>': the condition is shell text, run whole; a FAIL shows its output
  if said="$( (eval "$2") 2>&1)"; then pass "$1"; else fail "$1"; [ -z "$said" ] || printf '%s\n' "$said" | sed 's/^/       /'; fi
}
json_value() { python3 -c 'import json,sys; value=json.load(sys.stdin)
for key in sys.argv[1].split("."): value = value[int(key)] if key.isdigit() else value[key]
print(value if isinstance(value,str) else json.dumps(value))' "$1"; }
local_adapter="$plugin/adapters/local"
slug() { printf '%s' "$1" | tr ':/#' '---'; }
run_file() { printf '.flow/runs/%s.json' "$(slug "$1")"; }
state() { "$local_adapter/read.sh" "$1" | json_value "state.$2"; }
# ready_ids [list-ready options]: the ids of the ready items, one per line.
ready_ids() { "$local_adapter/list-ready.sh" "$@" | python3 -c 'import json,sys; print("\n".join(item["id"] for item in json.load(sys.stdin)))'; }
claim_base() { json_value base < "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json"; }
# set_claim_base <item> <name>: writes <name> as the base in the item's claim.json, as a hand could.
set_claim_base() { python3 -c 'import json,sys; path=sys.argv[1]; claim=json.load(open(path)); claim["base"]=sys.argv[2]; json.dump(claim,open(path,"w"))' "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json" "$2"; }
# The reason a claim gives for a base: name base_name_valid refuses, read from lib/base.sh.
base_name_refused="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && printf %s "$base_name_refused"')"
# epic_of <id>: the epic branch an id names, worked out by hand from the rule: the id past its
# last #, / or :, after epic/.
epic_of() { printf 'epic/%s' "$(printf '%s' "$1" | sed 's|.*[#/:]||')"; }
# The names no reader may hand on from a claim.json base, and no claim may record, by label. A tab
# shifts the fields of a claimed_bases record; the line breaks end one record and forge the next.
name_with_a_tab="$(printf 'plan/x\ty')"; name_with_a_shell_character='plan/x;id'
name_forging_a_record="$(printf 'plan/x\t/tmp\tfalse\nforged-item\tforged-base\t/tmp\ttrue\nleftover')"
name_git_reads_as_an_option='-x'; name_with_a_space='plan/x y'; name_climbing_a_level='plan/../x'
name_from_the_root='/plan/x'; name_with_a_letter_outside_ascii='plan/é'
tampered_labels="name_with_a_tab name_forging_a_record name_with_a_shell_character name_git_reads_as_an_option
  name_with_a_space name_climbing_a_level name_from_the_root name_with_a_letter_outside_ascii"

# new_repo <dir>: a clone of a fresh bare origin, on the local adapter with config base main, a
# three-worktree pool and behind_base 1; the shell in it. other is a second clone that moves the
# remote.
new_repo() {
  root="$work/$1"; mkdir -p "$root" && git init -q --bare "$root/origin.git" || exit 1
  git clone -q "$root/origin.git" "$root/app" 2>/dev/null && cd "$root/app" || exit 1
  git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main
  printf 'hi\n' > README.md && git add -A && git commit -qm init && git push -q -u origin main
  for worktree_number in 1 2 3; do git worktree add -q -b "main-wt-$worktree_number" "../wt-$worktree_number"; done
  mkdir -p .flow
  printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\npool_max: 8\nnotify:\n  desktop: false\njobs:\n  health:\n    behind_base: 1\n' > .flow/config.yaml
  git clone -q "$root/origin.git" "$root/other" 2>/dev/null
  git -C "$root/other" config user.email t@t && git -C "$root/other" config user.name t
}
# remote_branch <branch>: a new branch on the remote at main's tip.
remote_branch() { git -C "$root/other" fetch -q origin && git -C "$root/other" push -q origin "origin/main:refs/heads/$1"; }
# remote_commit <branch> <file>: one commit adding <file> on the remote <branch>.
remote_commit() { git -C "$root/other" fetch -q origin && git -C "$root/other" checkout -q -B "$1" "origin/$1" && printf '%s\n' "$2" > "$root/other/$2" && git -C "$root/other" add -- "$2" && git -C "$root/other" commit -qm "$2" && git -C "$root/other" push -q origin "$1"; }
body="## Acceptance
- [ ] done"
new_task() { "$plugin/scripts/new.sh" task "$1" --size S --body "${3:-$body}" ${2:+--parent "$2"}; }
move_task_numbers_past_the_epic_numbers() { for filler in "$@"; do "$local_adapter/create.sh" task "Filler $filler" --body x >/dev/null; done; }
