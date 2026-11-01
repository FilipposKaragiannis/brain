# ADR 0002: changelog fragments

Date: 2026-11-01. Status: accepted.

## Context
Every PR that changed a plugin raised `version` in its `plugin.source.json`, put a section on top
of its `CHANGELOG.md` and regenerated the manifests and both marketplace files. Parallel PRs read
the same version on main and picked the same next one: #67 and #77 both took flow 1.24.0. Each
merge then sent every open PR on that plugin back to merge main, renumber, rerun
`tools/generate.sh` and rerun the suites (#81). With a pool of three worktrees that hit most
merges.

## Decision
- A PR never touches a plugin's version, its `CHANGELOG.md` or the generated files a release
  changes. It adds one fragment per plugin it changes, `plugins/<plugin>/changelog.d/<slug>.md`
  (the slug is the branch or the item, so two PRs never write the same file): a
  `bump: major|minor|patch` line, a blank line, then the bullets exactly as they will stand under
  the version heading (`- ` lines, continuations indented two spaces, wrapped at 100 columns).
- `tools/release.sh [--dry-run] [plugin ...]` folds them. Per plugin, the highest bump among its
  fragments raises the version once, `## <version> (<YYYY-MM-DD>)` with the bullets (fragments in
  filename order) goes on top of `CHANGELOG.md` (created when missing), and the fragments are
  deleted. Then `tools/generate.sh` runs. A malformed fragment stops it with the file and the
  reason, before anything is written.
- `tools/lint.sh` fails on a malformed fragment and on anything but `.md` in a `changelog.d`.
- `.github/workflows/release.yml` runs on every push to main. When fragments exist it folds them
  on top of main, commits the result through the GitHub API (so GitHub signs it) to
  `release/next`, and opens or refreshes the release PR, titled
  `release: <plugin> <version>, ...` with the new CHANGELOG sections as its body. Nothing pushes
  to main: main's ruleset wants a PR and signed commits. The owner merges the release PR.
- Rejected: raising the version at merge time (a bot would push to main, which the ruleset
  forbids); an Unreleased section in `CHANGELOG.md` (every PR edits the same lines, so they
  conflict as before); a version taken from the history at install time (the hosts read the
  version from the committed manifest).

## Consequences
- Parallel PRs on one plugin touch different files, so they merge one after the other with no
  version or CHANGELOG conflict and no rerun of the generator or the suites.
- One release PR per batch of merges, not one release per merge. Each push to main rebuilds the
  release PR from main and every fragment on it, so it always holds everything unreleased.
  Merging it raises each plugin's version by exactly one step and its CHANGELOG section lists
  what that release holds, one group of bullets per merged PR. The version never skips or
  collides, and the manifests carry it, so the installed plugin's version changes when the
  release lands. Wanting one release per merge is merging the release PR after each merge.
- A change on main reaches the installed plugin only when its release PR merges.
- The release PR is opened with the workflow's token, and GitHub starts no workflow run for that
  token's events, so `ci.yml` does not run on it. The release job runs `tools/lint.sh` on the
  folded tree before it commits, which catches what a release can break: a stale generated file
  or a malformed fragment.
- The repository must allow GitHub Actions to create pull requests (Settings → Actions → General).
- ADR 0001's "a version bump is one edit" is now `tools/release.sh`'s edit, not the author's.
