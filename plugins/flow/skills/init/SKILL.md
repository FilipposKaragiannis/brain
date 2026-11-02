---
name: init
description: Install or refresh the flow plugin in this repository. Writes .flow/config.yaml (adapters, base branch, worktree pool and its growth, gates, notifications), the notify, unattended-run and worktree-hook scripts, the Codex rules and agents (in the repo's .codex/ or the user's ~/.codex), and an ignore block in .git/info/exclude so nothing of flow is tracked, then walks the owner through the config gaps. Use when a repo adopts the flow, after a plugin update, or to check the install is current (init --check is the one drift check).
disable-model-invocation: true
---

Install the flow plugin into the current repository, or refresh it after a plugin update.

## Steps

1. **Run the installer** from the repository root:
   ```
   "<plugin root>/skills/init/scripts/init.sh"
   ```
   The plugin root is the directory that holds this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on
   Codex, the path `codex plugin list` prints for `flow`). Run from a linked worktree, it works
   on the flow home, the main worktree's `.flow`, and says so. Add `--check` to only report drift
   and hand edits. The Codex rules and agents go to the repository's `.codex/` when it has one,
   and to the user's `~/.codex` when it has none or with `--user-codex`; the installer says which.
   If it refuses a file edited by hand, do not add `--force` for the owner: show the refusal and
   ask. The edit belongs in the plugin source.
2. **Read what it printed** and report once (W-07), in one short message: the files written,
   the `Gaps` list as is, what the owner reviews by hand, where the Codex rules and agents went
   (the `Codex rules and agents:` line), and that nothing is committed: `.flow/` stays out of git.
   When it prints a `git rm --cached` command for files an earlier install committed, pass it on
   as is; never run it.
   When the installer says the pool lists more worktrees than the default `pool_max`, say so first:
   each listed worktree becomes a task slot, so the owner trims the list or keeps it.
3. **On a first install, end that same message with the config questions**, one numbered list,
   each with the value the installer wrote and the one you recommend from the repository:
   `pool_max` (the parallelism budget; the pool grows to it on its own), `worktree_copy` (the
   git-ignored files a worktree needs: `.claude/settings.local.json`, local env files; read
   `.gitignore` for candidates), `worktree_setup` (restore or install commands a fresh checkout
   needs; read the CI workflow and the README for them), `gates` (project checks the verifier
   runs; scripts under `tools/` or `scripts/` named check, lint or verify; a gate that only
   matters for some files takes `command` and `paths`), `feel_test_paths`
   (the client or UI folders), `auto_gates` (leave `plan-approval` empty unless the owner says items are
   grilled and defined before they enter the backlog; then recommend `S,M`), `notify.idle` (true: the scheduled `next` job says once when nothing is ready), `notify.slack_webhook` (prefer the `FLOW_SLACK_WEBHOOK` environment variable on the session or the scheduler, so the URL stays out of the repository). `reviews.reviewers` (who each review round asks: `codex`, `claude`, `copilot` or a login; recommend only the reviewers that answer on this repo), `jobs.claude.model`/`jobs.claude.effort` and `jobs.codex.model`/`jobs.codex.effort` (the model and effort of the sessions the scheduled jobs start, one pair per host, passed as written; empty is the host's default; a Claude effort is low, medium, high, xhigh or max, a Codex one low, medium, high or xhigh). Never hold the report back for the
   answers. When the owner answers, write the accepted values into `.flow/config.yaml`, then run
   `init --check` and show that the gaps are closed.

## What the installer writes

| Target | Content | Re-run |
|---|---|---|
| `.flow/config.yaml` | adapters (where each kind of new item goes), `trackers` (the trackers board, next and health read), `ready` (`ready.needs` and `ready.priority_order`, for every tracker), base, github repo, pool (the linked worktrees under the main worktree's parent folder, not those under `.claude/worktrees` or `.flow/tmp`), `pool_max` and a commented `worktree_name`, `worktree_copy` and `worktree_setup`, `auto_gates`, gates, feel-test paths, notify, reviews, jobs (`jobs.claude` and `jobs.codex`: model and effort per host) | written once, never overwritten; `--check` reports a gap with its line when the flow cannot run with it (empty pool with `pool_max` 0, empty base, an adapter that does not exist, an `adapters` value `trackers` leaves out, an `auto_gates` entry other than `plan-approval`, a `jobs.host` other than claude or codex, an effort the host does not take). Missing Claude worktree hooks are a note, not a gap. It does not ask an existing config for `jobs.claude` or `jobs.codex`, and notes once that `jobs.model`/`jobs.effort` are deprecated when they are set |
| `.flow/plugin.sh` | finds the installed plugin when a wrapper runs: `$FLOW_PLUGIN`, else the newest flow in the Claude plugin cache, else the Codex one | replaced |
| `.flow/notify.sh` | wrapper around the plugin notify script | replaced |
| `.flow/run-unattended.sh` | the unattended loop for `claude` or `codex` | replaced |
| `.flow/hooks/worktree-*.sh` | Claude `WorktreeCreate`/`WorktreeRemove` wrappers; the owner adds the printed entry to `.claude/settings.json` | replaced |
| `<codex>/rules/flow.rules` | git and gh allowed outside the Codex sandbox | replaced |
| `<codex>/agents/*.toml` | the flow agents for Codex | replaced |
| `.git/info/exclude` | a marked block that ignores all of `.flow/` in this clone and its linked worktrees | block replaced |
| `.gitignore` | the flow block an older init wrote: removed when every line in it is one init wrote; a block the owner added to is left and named | block removed |
| `.flow/stamp` | a hash of the plugin's install set, then one hash per guarded copy | rewritten |

**Nothing is tracked.** Flow is one user's tool: everything under `.flow/` is ignored through the
clone's own `.git/info/exclude`, which every linked worktree shares and nobody commits, so a
teammate without flow carries none of it. From a linked worktree, flow reads the config and state
in the main worktree's `.flow` (`flow_home`). Only what a host needs stays in the repository: the
`.claude/settings.json` hook entry init prints (it runs `.flow/hooks` when the clone has them and
otherwise makes the worktree as Claude does with no hook, so `claude --worktree` works without
flow) and, when the repository keeps a `.codex/`, the Codex files. A repository that committed
`.flow/` before gets the `git rm -r --cached` command that stops it; init never runs it.

**Where the Codex files go (`<codex>`).** `--user-codex` puts them in `~/.codex` (`$CODEX_HOME`
when set), where Codex reads the user's own rules and agents in every project. Without it they go
where the last init put them (the stamp records it), else to the repository's `.codex/` when it
has one, else to `~/.codex`. Init says which on its `Codex rules and agents:` line.

**The guard.** `<codex>/rules/flow.rules` and `<codex>/agents/*.toml` are guarded: before replacing
one, `init` compares it with the stamp, refuses a hand edit (exit 1, the rest is installed) and
`--force` replaces it. The wrappers under `.flow/` are not guarded: they are flow's own and
always replaced. They hold no path and no version, so a plugin update changes none of them and
needs no `init`; only a release that changes a copied file does.

**The nudge.** The plugin's `SessionStart` hook compares the stamp's first line with the plugin
on disk and, when they differ and a copy really drifted, prints the drift and asks for `init`.
A version bump alone does not change the hash. It is silent in a project without
`.flow/config.yaml` and it does not look for hand edits; `init --check` does.

## Never

- Never edit `.flow/config.yaml` beyond the owner's answers in step 3. Suggest other changes.
- Never commit.
