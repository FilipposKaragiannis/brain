#!/bin/sh
# core-board.sh: parent and create, the board and its graphs, the worktree hooks, and the GitHub
# adapter through a fake gh.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
echo "parent and create"
c1="$("$P/adapters/local/create.sh" task "Child" --size S --parent "$v1")"
check "local parent"      [ "$("$P/adapters/local/read.sh" "$c1" | jget parent)" = "$v1" ]

echo "board"
board="$("$P/scripts/board.sh")"
check "board pool and items" sh -c "printf '%s' \"$board\" | grep -q '## Pool' && printf '%s' \"$board\" | grep -q 'local:task/2'"
check "board json"        sh -c "'$P/scripts/board.sh' --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"pool\"])==2 and d[\"items\"]'"

echo "board graphs (local)"
# Its own home, so these items never reach a later pick.
gh_home="$work/graph-home"; mkdir -p "$gh_home"; printf 'adapters:\n  default: local\n' > "$gh_home/config.yaml"
gr() { FLOW_HOME="$gh_home" "$@"; }
# mmd_edges <file>: each Mermaid edge as "<from item> <arrow> <to item> red|plain", in order.
mmd_edges() { python3 - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
ids = {m.group(1): m.group(2) for m in (re.match(r'\s+(n\d+)\["(\S+) ', l) for l in lines) if m}
red = set()
for l in lines:
    m = re.match(r"\s+linkStyle ([\d,]+) stroke:#b91c1c", l)
    if m: red |= set(m.group(1).split(","))
edges = [l.split() for l in lines if re.match(r"\s+n\d+ (-->|==>|-\.)", l)]
for n, e in enumerate(edges):
    print(ids[e[0]], " ".join(e[1:-1]), ids[e[-1]], "red" if str(n) in red else "plain")
PY
}
ge="$(gr "$P/adapters/local/create.sh" epic "Ship it" --priority P1)"
ga="$(gr "$P/adapters/local/create.sh" task 'Schema "v2" #3;' --size M --priority P2 --parent "$ge")"
gb="$(gr "$P/adapters/local/create.sh" task "API" --size L --priority P0 --parent "$ge" --blocked-by "$ga")"
gc="$(gr "$P/adapters/local/create.sh" task "UI" --size S --parent "$ge" --blocked-by "$ga,$gb")"
gd="$(gr "$P/adapters/local/create.sh" task "Elsewhere" --size S --priority P0)"
gr "$P/scripts/board.sh" --graph "$ge" > "$work/graph.json"
check_all "graph: a local epic layers its children in waves by longest path" '[ "$(jget waves < "$work/graph.json")" = "{\"1\": [\"$ga\"], \"2\": [\"$gb\"], \"3\": [\"$gc\"]}" ]'
check_all "graph: the critical path is the size-weighted longest chain" '[ "$(jget criticalPath < "$work/graph.json")" = "[\"$ga\", \"$gb\", \"$gc\"]" ]'
check_all "graph: only the epic's children are nodes, each with its priority" '[ "$(python3 -c "import json,sys; n=json.load(open(sys.argv[1]))[\"nodes\"]; print(sorted(n), n[sys.argv[2]][\"priority\"])" "$work/graph.json" "$gb")" = "[$(printf "'\''%s'\'', " "$ga" "$gb" "$gc" | sed "s/, $//")] P0" ]'
gr "$P/scripts/board.sh" --graph "$ge" --mermaid > "$work/graph.mmd"
check_all "graph --mermaid: a flowchart, one subgraph per wave" 'head -1 "$work/graph.mmd" | grep -qx "flowchart LR" && [ "$(grep -c "^  subgraph wave" "$work/graph.mmd")" = 3 ] && ! grep -q "^## Pool" "$work/graph.mmd"'
check_all "graph --mermaid: only the critical path's edges are thick and red" '[ "$(mmd_edges "$work/graph.mmd")" = "$(printf "%s\n" "$ga ==> $gb red" "$ga --> $gc plain" "$gb ==> $gc red")" ]'
check "graph --mermaid: a title cannot end its label or read as an entity" grep -q 'Schema #quot;v2#quot; #35;3;' "$work/graph.mmd"
gr "$P/scripts/board.sh" --graph priorities > "$work/prio.json"
check_all "graph priorities: one column per priority, highest first, each item in its own, no epics, no priority last" '[ "$(python3 -c "import json,sys; print(\" \".join((c[\"priority\"] or \"-\") + \":\" + \",\".join(c[\"items\"]) for c in json.load(open(sys.argv[1]))[\"columns\"]))" "$work/prio.json")" = "P0:$gb,$gd P2:$ga -:$gc" ] && ! grep -q "\"$ge\":" "$work/prio.json"'
check_all "graph priorities: a lower priority item blocking a higher one is an inversion" '[ "$(jget inversions < "$work/prio.json")" = "[[\"$ga\", \"$gb\"]]" ]'
gr "$P/scripts/board.sh" --graph priorities --mermaid > "$work/prio.mmd"
check_all "graph priorities --mermaid: the inversion is the one dashed red edge" '[ "$(mmd_edges "$work/prio.mmd")" = "$(printf "%s\n" "$ga -. inversion .-> $gb red" "$ga --> $gc plain" "$gb --> $gc plain")" ]'
check_all "graph: an id that is no open item says so" '! gr "$P/scripts/board.sh" --graph local:epic/99 2>"$work/graph.err" && grep -q "local:epic/99 is not an open item" "$work/graph.err"'
# Two branches of two steps each: the heavier one is critical, though the lighter one is listed first.
gf="$(gr "$P/adapters/local/create.sh" epic "Fork")"
fr="$(gr "$P/adapters/local/create.sh" task "Root" --size S --parent "$gf")"
fx="$(gr "$P/adapters/local/create.sh" task "Light" --size S --parent "$gf" --blocked-by "$fr")"
fy="$(gr "$P/adapters/local/create.sh" task "Heavy" --size L --parent "$gf" --blocked-by "$fr")"
fz="$(gr "$P/adapters/local/create.sh" task "Join" --size S --parent "$gf" --blocked-by "$fx,$fy")"
check_all "graph: the critical path weighs size, not only steps" '[ "$(gr "$P/scripts/board.sh" --graph "$gf" | jget criticalPath)" = "[\"$fr\", \"$fy\", \"$fz\"]" ]'
sed -i.bak "s|^blocked_by: .*|blocked_by: [$gc]|" "$gh_home/items/${ga#local:}.md"
check_all "graph: blockers in a cycle end it with a word, not a hang" '! gr "$P/scripts/board.sh" --graph "$ge" 2>"$work/graph.err" && grep -q "form a cycle" "$work/graph.err"'
check_all "graph: --mermaid alone is refused, and says why" '! gr "$P/scripts/board.sh" --mermaid 2>"$work/graph.err" && grep -q -- "--mermaid goes with --graph" "$work/graph.err"'

echo "worktree hooks"
rm -f .flow/runs/*.json
"$P/scripts/steward.sh" release "$t2" --force >/dev/null 2>&1
path="$(printf '{"name":"local-task-2","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
check_all "WorktreeCreate claims a pool path" '[ -d "$path" ] && [ "$(jget item < "$path/.flow/claim.json")" = "$t2" ]'
printf 'x\n' > "$path/keep.txt"
printf '{"worktree_path":"%s","cwd":"%s"}' "$path" "$PWD" | "$P/hooks/worktree-remove.sh" >/dev/null 2>&1; code=$?
check_all "WorktreeRemove keeps a dirty worktree (exit 3)" '[ "$code" -eq 3 ] && [ -f "$path/keep.txt" ]'
rm "$path/keep.txt"
printf '{"worktree_path":"%s","cwd":"%s"}' "$path" "$PWD" | "$P/hooks/worktree-remove.sh" >/dev/null 2>&1; code=$?
check_all "WorktreeRemove releases a clean worktree" '[ "$code" -eq 0 ] && [ ! -f "$path/.flow/claim.json" ]'
check_all "WorktreeRemove leaves the pool path in place, on its idle branch at the base, registered with git" '[ -d "$path" ] && [ "$(git -C "$path" symbolic-ref --short HEAD)" = "main-$(basename "$path")" ] && [ "$(git -C "$path" rev-parse HEAD)" = "$(git rev-parse main)" ] && git worktree list --porcelain | grep -qx "worktree $path"'
adhoc="$(printf '{"name":"bold-oak","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
check_all "WorktreeCreate ad hoc name" '[ -d "$adhoc" ] && [ "$(jget item < "$adhoc/.flow/claim.json")" = "adhoc:bold-oak" ]'
"$P/scripts/steward.sh" release "$adhoc" --force >/dev/null 2>&1

echo "github adapter (fake gh)"
. "$here/_github_fixture.sh"
item="$("$P/adapters/github/read.sh" 'gh#11')"
check_all "gh read"           '[ "$(printf '\''%s'\'' "$item" | jget title)" = "Task one" ] && [ "$(printf '\''%s'\'' "$item" | jget size)" = "S" ] && [ "$(printf '\''%s'\'' "$item" | jget kind)" = "task" ]'
check "gh read epic kind" [ "$("$P/adapters/github/read.sh" 'gh#10' | jget kind)" = "epic" ]
check "gh list open"      [ "$("$P/adapters/github/list.sh" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "3" ]
check "gh list-ready excludes blocked" [ "$("$P/adapters/github/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "gh#10,gh#11" ]
"$P/adapters/github/write-state.sh" 'gh#11' step=implement worktree=wt-1 profile=task-S attempts=1 last_event="t start" touches=src/**
check "gh labels mirrored" sh -c "grep -q 'issue edit 11 .*--add-label step:implement --add-label wt:wt-1 --add-label flow:task-S' '$FAKE_GH_DIR/calls.log'"
item="$("$P/adapters/github/read.sh" 'gh#11')"
check_all "gh state round trip" '[ "$(printf '\''%s'\'' "$item" | jget state.step)" = "implement" ] && [ "$(printf '\''%s'\'' "$item" | jget state.attempts)" = "1" ] && [ "$(printf '\''%s'\'' "$item" | jget state.worktree)" = "wt-1" ] && [ "$(printf '\''%s'\'' "$item" | jget state.touches)" = '\''["src/**"]'\'' ]'
"$P/adapters/github/write-state.sh" 'gh#11' step=test gate=none
check "gh label replaced" sh -c "grep -q 'add-label step:test --remove-label step:implement' '$FAKE_GH_DIR/calls.log'"
check "gh one state comment" [ "$(python3 -c 'import json; print(len([c for c in json.load(open("'"$FAKE_GH_DIR"'/issues.json"))["issues"][1]["comments"] if "flow:state" in c["body"]]))')" = "1" ]
"$P/adapters/github/comment.sh" 'gh#11' --body "hello"
"$P/adapters/github/link-pr.sh" 'gh#11' https://gh/pr/5
check "gh link-pr"        [ "$("$P/adapters/github/read.sh" 'gh#11' | jget state.pr)" = "https://gh/pr/5" ]
"$P/adapters/github/close.sh" 'gh#11' --comment done
check "gh close"          [ "$("$P/adapters/github/read.sh" 'gh#11' | jget status)" = "closed" ]
check "gh next.sh end to end" sh -c "'$P/scripts/next.sh' --json | grep -q '\"item\":\"gh#10\"'"
check "cross-tracker blocker: local waits on gh" sh -c "'$P/adapters/local/create.sh' task Cross --blocked-by 'gh#12' >/dev/null && ! '$P/adapters/local/list-ready.sh' | grep -q Cross"

[ "$fails" -eq 0 ] && { echo "core-board: ok"; exit 0; }
echo "core-board: $fails failed"; exit 1
