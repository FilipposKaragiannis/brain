# _flow_setup.sh: the setup every suite cut from run.sh sources once it is in the sandbox: stubs
# for the network, desktop and agent tools, a ps that cannot run, the check helpers, and a
# throwaway repo with a two-worktree pool on the local adapter, with lib/flow.sh sourced. Takes
# the plugin folder in $P and the work folder in $work, and leaves the shell in the repo.
# Sourced, never run.
# No test reaches the network, the desktop or a real agent: these tools are stubs that log to
# $work/offline.log. A test that needs one of them puts its own fake earlier in PATH.
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
# A ps that cannot run, as a sandbox refuses the setuid /bin/ps on macOS. A test that needs it puts
# this folder first in PATH.
refused_ps="$work/refused-ps"
mkdir -p "$refused_ps" && printf '#!/bin/sh\necho "ps: Operation not permitted" >&2\nexit 126\n' > "$refused_ps/ps" && chmod +x "$refused_ps/ps"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> <condition command...>
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
check_all() { # check_all <name> '<condition>': the condition is shell text run whole, so every
  # part of an && or || chain or a pipe is tested, not only the part before the first operator.
  name="$1"; shift
  if eval "$1" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
jget() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
# claim_step <item>: the step the pool table shows for the item's claim.
claim_step() { "$P/scripts/steward.sh" pool | awk -v item="$1" '$3 == item { print $4 }'; }
# record <command> <argument>...: the flow record of the project in the current folder.
record() { "$P/scripts/state.sh" "$@"; }
# archived <item> <path>: a field of the item's record once its release archived it.
archived() { open_record="$(record path "$1")"; jget "$2" < "$(dirname "$open_record")/closed/$(basename "$open_record")"; }
# end_run <item>: the item's run is over, as when its agent is gone.
end_run() { record set "$1" run:=null; }
# running_items: every item with a run in its record, one per line.
running_items() { record list runs | python3 -c 'import json,sys
for line in sys.stdin: print(json.loads(line)["item"])'; }
# end_runs: every run in the project is over.
end_runs() { for running_item in $(running_items); do end_run "$running_item"; done; }
# running <item>: yes when the item's record holds a run, else no.
running() { if [ -n "$(record get "$1" run)" ]; then echo yes; else echo no; fi; }
# gate_with <item> <key> <value>: the item's raised gate with one key set to the value.
gate_with() {
  edited_gate="$(record list gates "$1" | python3 -c 'import json,sys
gate = json.load(sys.stdin); gate[sys.argv[1]] = sys.argv[2]; print(json.dumps(gate))' "$2" "$3")" &&
    record set "$1" "gate:=$edited_gate"
}

cd "$work"
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init
git worktree add -q --detach ../wt-1 && git worktree add -q --detach ../wt-2
mkdir -p .flow
cat > .flow/config.yaml <<'YAML'
adapters:
  default: local
base: main
pool:
  - ../wt-1
  - ../wt-2
notify:
  desktop: false
YAML
repo="$PWD"

. "$P/lib/flow.sh"
