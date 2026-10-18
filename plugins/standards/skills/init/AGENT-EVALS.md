# Writing an agent eval case

An agent eval plants a bug in a copy of the repo and checks that the project agent whose job it
is finds it. The cases are the project's own; the plugin ships only the runner,
`.standards/evals/run.sh`, which `init` installs when the config names a `project.roster`.

## Where the cases go
Set `project.evals` in `.standards/config.json` to a repo-relative folder, one subfolder per case
in the `claude plugin eval` format:

```
AI/agents/evals/
  _fixture.sh                        shared scaffold helper (optional)
  security-reviewer-flags-sql-concat/
    case.yaml                        runs, turns, tools, the scaffold script
    prompt.md                        what the session is asked
    scaffold.sh                      builds the fixture repo in the run's temp dir
    plant.patch                      the planted bug, one diff against HEAD
    graders/*.md                     one grader per file
```

The runner assembles a throwaway wrapper plugin with copies of `.claude/agents/*.md` and of this
folder, so the agents run as `<repo folder>:<name>`. A scaffold script runs from that copy and
sees none of the runner's environment, so it reads the repo's path from `.repo-root`, which the
runner writes beside the cases: `"$(cat "$case_dir/../.repo-root")"`.

## A planted bug
`case.yaml`:

```yaml
schema_version: "1.1"
name: security-reviewer-flags-sql-concat
runs: 3
execution:
  max_turns: 30
  timeout_seconds: 1200
  allowed_tools: [Agent, Bash, Read, Glob, Grep]
context:
  scaffold_script: scaffold.sh
```

`scaffold.sh` runs in an empty temp dir. It copies the slice of the repo at `HEAD` the agent
needs, commits it on `main`, then applies the plant on a branch:

```sh
#!/bin/sh
set -e
case_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cat "$case_dir/../.repo-root")"
git -C "$root" archive --format=tar HEAD -- AGENTS.md .standards src/orders | tar -xf -
git init -q -b main . && git config user.email eval@example.com && git config user.name eval
git add -A && git commit -qm "chore: baseline"
git switch -q -c feature && git apply "$case_dir/plant.patch"
git add -A && git commit -qm "feat(orders): search orders by customer name"
```

`plant.patch`, a query built by string concatenation on a path the reviewer's roster `paths`
cover:

```diff
--- a/src/orders/search.py
+++ b/src/orders/search.py
@@ -10,5 +10,5 @@ def find_by_customer(db, name):
-    return db.execute("SELECT * FROM orders WHERE customer = ?", (name,))
+    return db.execute("SELECT * FROM orders WHERE customer = '" + name + "'")
```

`prompt.md` asks for the review and the report, not for a review of its own:

```
Review the changes on this branch since `main` with the project's `security-reviewer` agent.
Give it `git diff main...HEAD` and `git log --oneline main..HEAD`, wait for its report, then
reply with its findings verbatim. Do not review the diff yourself.
```

## Graders
One file each under `graders/`; give a case all three kinds.

The right agent ran (`tool_used` on `Agent`; the prefix is the wrapper's name):

```
---
type: tool_used
tool: Agent
input_match: '"subagent_type"\s*:\s*"(?:[\w-]+:)?security-reviewer"'
arm: with-only
---
```

The report grades it at the right severity against the right rule (`regex` on the last message):

```
---
type: regex
pattern: "([Cc]oncatenat|[Ii]njection)[\\s\\S]*P0|P0[\\s\\S]*([Cc]oncatenat|[Ii]njection)"
flags: ""
match: contains
target: last_message
---
The report grades the concatenated query P0.
```

The finding is the real one (`llm`, judged by the runner's `--judge-model sonnet`):

```
---
type: llm
---
The final message reports a P0 SQL injection in `src/orders/search.py`, in `find_by_customer`,
for building the query from `name` by string concatenation, and gives the fix as a bound
parameter. Other findings may also appear.
```

## Running
```sh
.standards/evals/run.sh                                   # every case, the runs case.yaml sets
.standards/evals/run.sh --case 'security-*' --runs 1      # one case, one run
```

Results go to `.standards/evals/results/<time>/` (git-ignored). Each run spawns the agent under
test with its own model, so a full run costs money; it never runs in CI. Run it after changing a
brief or the roster. A plant that no longer applies to `HEAD` fails the scaffold: make the same
edit on the current code and regenerate `plant.patch`.

This runs on Claude only: Codex has no plugin eval. The Codex agents render from the same briefs,
so a brief that passes here carries over.
