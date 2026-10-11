#!/bin/sh
# Shared fixture for the flow step evals: a repo with the flow config, a pool worktree inside
# the repo (the eval sandbox allows writes under the repo only), one local item, and the
# step prepared with next.sh so the skill finds the claim, the run and the brief.
#   . _scaffold-common.sh; scaffold <kind> <size> <title> <step-state> [implemented]
# With "implemented", the fix is committed on the task branch in the pool worktree first, so
# the steps after implement (test, verify, explain, pr) have a change to work on.
scaffold() {
  set -e
  P=/work/brain/plugins/flow
  git init -q -b main .
  git config user.email eval@example.com
  git config user.name eval
  mkdir -p src tests docs .standards .flow
  printf '# Project\n\nA tiny shell project. Build: sh -n src/*.sh. Tests: sh tests/run.sh.\n' > AGENTS.md
  printf '#!/bin/sh\n# greet <name>: prints a greeting\nprintf "hello %%s\\n" "$1"\n' > src/greet.sh
  printf '#!/bin/sh\nout="$(sh src/greet.sh bob)"; [ "$out" = "hello bob" ] || { echo "greet failed because the output was $out"; exit 1; }\necho ok\n' > tests/run.sh
  printf '{"version":"0.1.0","build":"sh -n src/*.sh","test":"sh tests/run.sh","mutation":"","languages":[],"protected":[]}\n' > .standards/config.json
  printf '# Testing guide\n\nUnit tests: `sh tests/run.sh`, one assertion per test with a because string in the failure message.\n' > .standards/testing-guide.md
  printf '.pool/\n.flow/items/\n.flow/reports/\n.flow/runs/\n.flow/gates/\n.flow/claim.json\n.flow/events.log\n.flow/next.txt\n' > .gitignore
  printf 'adapters:\n  default: local\nbase: main\npool:\n  - .pool/wt-1\nnotify:\n  desktop: false\n' > .flow/config.yaml
  # Install stamps that match the plugins on disk, so the session-start hooks stay quiet: the
  # fixture stands for a project whose init ran already.
  (FLOW_PLUGIN="$P"; . "$P/lib/flow.sh"; printf 'source\t%s\n' "$(flow_source_hash "$P")" > .flow/stamp)
  (STANDARDS_HOOKS=/work/brain/plugins/standards/hooks; . "$STANDARDS_HOOKS/lib.sh"; printf 'source\t%s\n' "$(standards_source_hash /work/brain/plugins/standards)" > .standards/stamp)
  git add -A && git commit -qm "chore: initial"
  mkdir -p .pool && git worktree add -q --detach .pool/wt-1
  export FLOW_PLUGIN="$P"
  id="$("$P/adapters/local/create.sh" "$1" "$3" --size "$2" --body "## What
$3

## Acceptance
- [ ] greet prints \"hello <name>\" for any name
- [ ] greet with no argument prints \"hello stranger\"")"
  [ -n "$4" ] && "$P/adapters/local/write-state.sh" "$id" "step=$4"
  "$P/scripts/next.sh" "$id" > .flow/next.txt
  if [ "${5:-}" = "implemented" ]; then
    wt="$PWD/.pool/wt-1"
    printf '#!/bin/sh\n# greet [name]: prints a greeting; a missing name greets a stranger\nprintf "hello %%s\\n" "${1:-stranger}"\n' > "$wt/src/greet.sh"
    git -C "$wt" add -A && git -C "$wt" commit -qm "feat(greet): greet strangers when no name is given"
  fi
  set +e
}
