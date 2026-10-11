#!/bin/sh
# Install or refresh the standards plugin in a repository.
#   init.sh [--root <repo>] [--check] [--force] [--source-hash]
# Writes under its own folder: .standards/config.json (once), .standards/testing-guide.md (once),
# .standards/rules/*.md, .standards/hooks/* and .standards/stamp (what it wrote; see stamp.sh).
# Outside it only what the hosts and git mandate: the marked block in AGENTS.md (and a separate
# CLAUDE.md), .claude/rules/standards-*.md, .codex/agents/*.toml, the git hooks (a call appended
# to the project's own .githooks/pre-commit, commit-msg and pre-push when that folder exists, else
# core.hooksPath pointed at .standards/hooks/git), and, when .standards/config.json "project"
# names them, the skills and rules links (.claude/skills, .agents/skills, .claude/rules/project)
# and the project roster rendered into .claude/agents/ and .codex/agents/. The agent hosts run
# the gates from the plugin's own hooks/hooks.json: init writes no hook entry into a host
# settings file, and reports one that would run the gates twice. Old copies under docs/ (before
# v0.2.0) are removed when unchanged, or reported.
# Re-running replaces only what it wrote, and refuses a copy edited by hand since (exit 1; --force
# replaces it). --check reports drift and hand edits and writes nothing (exit 1 on either).
# --source-hash prints the hash of the plugin's install set and exits (the session-start hook).
set -u
plugin="$(cd "$(dirname "$0")/../../.." && pwd)"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
check=0; force=0; source_hash=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --check) check=1; shift ;;
    --force) force=1; shift ;;
    --source-hash) source_hash=1; shift ;;
    *) echo "init: unknown argument $1" >&2; exit 2 ;;
  esac
done
STANDARDS_HOOKS="$plugin/hooks"; . "$plugin/hooks/lib.sh"
source_hash() { standards_source_hash "$plugin"; }   # the install set lives in hooks/lib.sh
[ "$source_hash" -eq 1 ] && { source_hash; exit 0; }
cd "$root" || exit 2
version="$(json_get "$(cat "$plugin/.claude-plugin/plugin.json")" "version")"
begin="<!-- standards:begin v$version -->"
end="<!-- standards:end -->"
stamp=".standards/stamp"
drift=0; refused=0
changed=""; stamped=""; kept=""
note() { changed="$changed  $1
"; }
drifted() { drift=1; echo "init: drift: $1"; }
gaps=""
gap() { gaps="$gaps  - $1
"; [ "$check" -eq 1 ] && { drift=1; echo "init: gap: $1"; }; }
edited() {
  if [ "$check" -eq 1 ]; then drift=1; echo "init: edited by hand: $1"
  else refused=1; echo "init: refused: $1 was edited by hand since init last wrote it; move the edit to the plugin source, or re-run with --force"; fi
}
install_file() {
  # install_file <built file> <target> [mode]: replace the target when it differs from the built
  # file, unless the target also differs from what init last wrote (a hand edit) and --force is
  # off. Every target handled here lands in the stamp.
  if [ -f "$2" ] && cmp -s "$1" "$2"; then stamped="$stamped $2"; return; fi
  if [ -f "$2" ] && [ "$force" -eq 0 ]; then
    last="$(stamp_get "$stamp" "$2")"
    if [ -n "$last" ] && [ "$last" != "$(hash_file "$2")" ]; then edited "$2"; kept="$kept $2"; return; fi
  fi
  if [ "$check" -eq 1 ]; then drifted "$2"; else mkdir -p "$(dirname "$2")" && cp "$1" "$2" && { [ -z "${3:-}" ] || chmod "$3" "$2"; } && note "$2"; fi
  stamped="$stamped $2"
}
write_stamp() {
  tmp="$(tmpfile stamp)"
  {
    printf 'source\t%s\n' "$(source_hash)"
    for t in $stamped; do printf '%s\t%s\n' "$(hash_file "$t")" "$t"; done
    for t in $kept; do printf '%s\t%s\n' "$(stamp_get "$stamp" "$t")" "$t"; done
  } > "$tmp"
  if [ ! -f "$stamp" ] || ! cmp -s "$tmp" "$stamp"; then cp "$tmp" "$stamp" && note "$stamp"; fi
}

realpath_py() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
die() { echo "init: $1" >&2; exit 1; }

# Scratch files live inside the repo: mktemp is not available in every sandbox, and a failed
# temp file must never truncate a target.
scratch=".standards/.init-tmp"
mkdir -p "$scratch" || die "cannot create $scratch"
trap 'rm -rf "$scratch"' EXIT
tmpfile() { printf '%s/%s' "$scratch" "$1"; }

# 1. Project config, written once from what the repo contains.
if [ ! -f .standards/config.json ]; then
  if [ "$check" -eq 1 ]; then drifted ".standards/config.json is missing"; else
    mkdir -p .standards
    solutions="$(find . -maxdepth 3 -name '*.sln' -not -path './.git/*' | sed 's|^\./||' | sort)"
    python3 - "$version" $solutions > .standards/config.json <<'PY'
import json, os, sys
version, solutions = sys.argv[1], sys.argv[2:]
languages = []
if solutions:
    languages.append({
        "name": "csharp", "extensions": [".cs"],
        "format": [{"prefix": (os.path.dirname(s) + "/") if os.path.dirname(s) else "",
                    "command": "dotnet format style %s --verify-no-changes --no-restore --include {files}" % s}
                   for s in solutions],
        "comments": {"line": "//", "doc": "///", "public": "public", "doc_inside": ["interface", "enum"], "allow_markers": ["float-boundary:"]},
    })
config = {
    "_readme": "Project settings for the standards plugin hooks and the flow verifier. Edit freely; init never overwrites this file. format[].command runs from the repo root with {files} replaced by the staged files under prefix. build runs in the git pre-push hook and in verify; test and mutation run in verify (mutation is a signal). protected files need [config] in the commit message. comments: line and doc are the comment tokens, public the modifier a doc comment must sit above, doc_inside the type kinds whose members may carry a doc without it (their members have no modifier), allow_markers the prefixes that make a line comment legal. gates: the project's own gates, run by the plugin hook, the git hooks and CI (check-gates.sh): {name, command, paths, when: [commit|push|ci]} runs command when a committed file matches a path glob; {name, forbid: [text], marker} blocks a command containing a text unless it carries the marker. project: skills (a folder; init links .claude/skills and .agents/skills to it), rules (a folder; init links .claude/rules/project to it), roster (a roster JSON in the marketplace schema; init renders it into .claude/agents/ and .codex/agents/, and the review skill spawns its reviewers by paths). Empty strings mean none.",
    "version": version,
    "languages": languages,
    "build": " && ".join("dotnet build %s --nologo" % s for s in solutions),
    "test": " && ".join("dotnet test %s --nologo --no-build" % s for s in solutions),
    "mutation": "dotnet stryker" if os.path.exists(".config/dotnet-tools.json") and "stryker" in open(".config/dotnet-tools.json").read() else "",
    "protected": [".editorconfig", "**/Directory.Build.props", "**/*.ruleset", "**/.globalconfig", ".github/workflows/**", ".githooks/**", ".standards/**"],
    "hot_paths": [],
    "review": {"security_paths": [], "performance_paths": []},
    "gates": [],
    "project": {"skills": "", "rules": "", "roster": ""},
}
print(json.dumps(config, indent=2))
PY
    [ -s .standards/config.json ] || die "could not write .standards/config.json"
    note ".standards/config.json written from the repo layout. Review it."
  fi
fi

# 1b. Old locations (before v0.2.0 the rule text and the testing guide lived under docs/).
# A rule copy goes when it is what init last wrote or what the plugin ships; the guide moves when
# it is still the plugin's template (its first lines say so) and nothing sits at the new path.
for src in "$plugin"/rules/common/*.md "$plugin"/rules/csharp.md; do
  old="docs/standards/$(basename "$src")"; [ -f "$old" ] || continue
  if [ "$check" -eq 1 ]; then drifted "stale: $old (the rule text now lives in .standards/rules/)"; continue; fi
  if cmp -s "$src" "$old" || [ "$(stamp_get "$stamp" "$old")" = "$(hash_file "$old")" ]; then rm -f "$old" && note "$old removed (now .standards/rules/)"
  else echo "init: $old is not what init wrote; move your edit to the plugin source, then delete it"; fi
done
[ -d docs/standards ] && rmdir docs/standards 2>/dev/null && note "docs/standards/ removed (empty)"
if [ -f docs/testing-guide.md ]; then
  if [ "$check" -eq 1 ]; then drifted "stale: docs/testing-guide.md (the guide now lives in .standards/)"
  elif [ ! -f .standards/testing-guide.md ] && grep -q 'standards:init' docs/testing-guide.md; then
    mkdir -p .standards && mv docs/testing-guide.md .standards/testing-guide.md && note ".standards/testing-guide.md moved from docs/ (your edits kept)"
  elif [ -f .standards/testing-guide.md ] && cmp -s docs/testing-guide.md .standards/testing-guide.md; then rm -f docs/testing-guide.md && note "docs/testing-guide.md removed (same as .standards/testing-guide.md)"
  else echo "init: docs/testing-guide.md is not the plugin's guide, or .standards/testing-guide.md differs; merge by hand, then delete it"; fi
fi

# 1c. The testing guide, written once with the detected commands (python: a command may hold &).
if [ ! -f .standards/testing-guide.md ]; then
  if [ "$check" -eq 1 ]; then drifted ".standards/testing-guide.md is missing"; else
    cfg_json="$(cat .standards/config.json)"
    t="$(json_get "$cfg_json" test)"; m="$(json_get "$cfg_json" mutation)"
    python3 -c 'import sys
template, test, mutation = sys.argv[1:4]
sys.stdout.write(open(template, encoding="utf-8").read().replace("{{test}}", test).replace("{{mutation}}", mutation))' \
      "$plugin/templates/testing-guide.md" "${t:-<test command>}" "${m:-<mutation command>}" > .standards/testing-guide.md
    [ -s .standards/testing-guide.md ] || die "could not write .standards/testing-guide.md"
    note ".standards/testing-guide.md written once. Fill in the fixtures and the hand-test list."
  fi
fi

# 2. Full rule text.
for src in "$plugin"/rules/common/*.md "$plugin"/rules/csharp.md; do
  install_file "$src" ".standards/rules/$(basename "$src")"
done

# 3. The marked block in AGENTS.md, and in CLAUDE.md when that is a different file.
install_block() {
  target="$1"
  tmp="$(tmpfile block)"
  if [ -f "$target" ] && grep -q '<!-- standards:begin' "$target"; then
    awk -v begin="$begin" -v end="$end" -v block="$plugin/rules/block.md" '
      /<!-- standards:begin/ { print begin; while ((getline line < block) > 0) print line; print end; skip = 1; next }
      /<!-- standards:end -->/ { skip = 0; next }
      !skip { print }' "$target" > "$tmp"
  else
    { [ -f "$target" ] && cat "$target"; [ -f "$target" ] && echo; echo "$begin"; cat "$plugin/rules/block.md"; echo "$end"; } > "$tmp"
  fi
  [ -s "$tmp" ] || die "could not build the block for $target"
  if [ ! -f "$target" ] || ! cmp -s "$tmp" "$target"; then
    if [ "$check" -eq 1 ]; then drifted "$target block"; else cat "$tmp" > "$target" && note "$target: standards block v$version"; fi
  fi
}
if [ -e AGENTS.md ]; then install_block AGENTS.md; elif [ -e CLAUDE.md ]; then install_block CLAUDE.md; else install_block AGENTS.md; fi
if [ -e CLAUDE.md ] && [ -e AGENTS.md ] && [ "$(realpath_py CLAUDE.md)" != "$(realpath_py AGENTS.md)" ]; then install_block CLAUDE.md; fi

# 4. Claude path-scoped rules, one per section, scoped to the configured source extensions.
globs="$(json_list "$(config_text)" "languages" | while read -r lang; do json_list "$lang" "extensions"; done | sed 's|^|  - "**/*|; s|$|"|')"
[ -n "$globs" ] || globs='  - "**/*"'
mkdir -p .claude/rules
for src in "$plugin"/rules/common/*.md "$plugin"/rules/csharp.md; do
  name="$(basename "$src" .md | sed 's/^[0-9]*-//')"
  dst=".claude/rules/standards-$name.md"
  tmp="$(tmpfile rule)"
  { echo "---"; echo "paths:"; echo "$globs"; echo "---"; cat "$src"; } > "$tmp"
  [ -s "$tmp" ] || die "could not build $dst"
  install_file "$tmp" "$dst"
done

# 5. Codex agents (Codex cannot load agents from a plugin).
mkdir -p .codex/agents
for src in "$plugin"/codex-agents/*.toml; do
  install_file "$src" ".codex/agents/$(basename "$src")"
done

# 6. Hook copies for the git hooks (hosts run the plugin's own copies).
mkdir -p .standards/hooks/git
for src in "$plugin"/hooks/*.sh "$plugin"/hooks/git/*; do
  case "$src" in */git/*) dst=".standards/hooks/git/$(basename "$src")" ;; *) dst=".standards/hooks/$(basename "$src")" ;; esac
  install_file "$src" "$dst" +x
done
# Wiring git to them. The plugin never creates .githooks/: a project that has one keeps it and
# gets one appended call per hook; a project without one points core.hooksPath (local git config,
# per clone) at the plugin's own folder.
hooks_path="$(git config core.hooksPath 2>/dev/null || true)"
if [ -d .githooks ]; then
  for hook in pre-commit commit-msg pre-push; do
    call="\"\$(git rev-parse --show-toplevel)/.standards/hooks/git/$hook\" \"\$@\" || exit 1  # standards plugin"
    if [ ! -f ".githooks/$hook" ]; then
      if [ "$check" -eq 1 ]; then drifted ".githooks/$hook"; else printf '#!/bin/sh\n%s\n' "$call" > ".githooks/$hook" && chmod +x ".githooks/$hook" && note ".githooks/$hook"; fi
    elif ! grep -qF ".standards/hooks/git/$hook" ".githooks/$hook"; then
      if [ "$check" -eq 1 ]; then drifted ".githooks/$hook lacks the standards call"; else printf '%s\n' "$call" >> ".githooks/$hook" && note ".githooks/$hook: standards call appended"; fi
    fi
  done
  wanted=".githooks"
else
  wanted=".standards/hooks/git"
fi
if [ -z "$hooks_path" ]; then
  if [ "$check" -eq 1 ]; then drifted "core.hooksPath is unset (wanted $wanted)"
  elif git config core.hooksPath "$wanted" 2>/dev/null; then note "git config core.hooksPath $wanted"
  else echo "init: could not set core.hooksPath. Run: git config core.hooksPath $wanted"; fi
elif [ "$hooks_path" != "$wanted" ]; then
  echo "init: core.hooksPath is $hooks_path, not $wanted. Call .standards/hooks/git/pre-commit, commit-msg and pre-push from your hooks."
fi

# 7. Host wiring. Both hosts run the gates from the plugin's hooks/hooks.json once the plugin is
# enabled, so init writes no PreToolUse entry: one in .claude/settings.json or .codex/hooks.json
# would run every gate a second time (hooks merge, they do not deduplicate). What a project needs
# is the plugin enabled at project scope; the host's install command writes that, with the
# marketplace name, so init reports when it is missing instead of guessing the file.
marketplace="$(printf '%s' "$plugin" | sed -n 's|.*/cache/\([^/]*\)/standards/[^/]*$|\1|p')"
if ! { [ -f .claude/settings.json ] && grep -q '"standards@' .claude/settings.json; }; then
  echo "init: note: Claude does not enable the plugin at project scope. Run: claude plugin install standards@${marketplace:-<marketplace>} --scope project (writes enabledPlugins in .claude/settings.json; every clone installs once)"
fi
if ! { [ -f .codex/config.toml ] && grep -q 'plugins."standards@' .codex/config.toml; }; then
  echo "init: note: Codex does not enable the plugin in .codex/config.toml. Add: [plugins.\"standards@${marketplace:-<marketplace>}\"] enabled = true"
fi
for settings in .claude/settings.json .codex/hooks.json; do
  [ -f "$settings" ] || continue
  dup="$(grep -oE 'check-(no-verify|config|comments|format|gates)\.sh' "$settings" | sort -u | tr '\n' ' ')"
  [ -n "$dup" ] || continue
  if [ "$check" -eq 1 ]; then drifted "stale: $settings runs $dup as project hooks; the plugin runs them, so they run twice. Remove the entries."
  else echo "init: $settings runs $dup as project hooks; the plugin runs them, so they run twice. Remove the entries (init never edits a host settings file)."; fi
done

# 8. Links to the project's shared skills and rules folders, when the config names them.
cfg_json="$(cat .standards/config.json)"
ensure_link() {
  # $1 link path, $2 target folder (repo-relative). The link is relative, so clones and worktrees
  # share it.
  rel="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1]) or "."))' "$1" "$2")"
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$rel" ]; then return; fi
  if [ -e "$1" ] && [ ! -L "$1" ]; then
    if [ "$check" -eq 1 ]; then drifted "$1 exists and is not a link to $2"; else echo "init: $1 exists and is not a link; move it aside, then re-run"; fi
    return
  fi
  if [ "$check" -eq 1 ]; then drifted "$1 -> $rel"; else mkdir -p "$(dirname "$1")" && rm -f "$1" && ln -s "$rel" "$1" && note "$1 -> $rel"; fi
}
project_skills="$(json_get "$cfg_json" project.skills)"
project_rules="$(json_get "$cfg_json" project.rules)"
if [ -n "$project_skills" ]; then
  [ -d "$project_skills" ] || echo "init: project.skills folder $project_skills does not exist"
  ensure_link .claude/skills "$project_skills"
  ensure_link .agents/skills "$project_skills"
fi
[ -n "$project_rules" ] && { [ -d "$project_rules" ] || echo "init: project.rules folder $project_rules does not exist"; ensure_link .claude/rules/project "$project_rules"; }

# 9. The project roster, rendered into both hosts' agent folders with the plugin's templates.
project_roster="$(json_get "$cfg_json" project.roster)"
if [ -n "$project_roster" ]; then
  if [ ! -f "$project_roster" ]; then
    if [ "$check" -eq 1 ]; then drifted "project.roster $project_roster is missing"; else echo "init: project.roster $project_roster does not exist"; fi
  else
    out="$scratch/agents"
    python3 "$plugin/skills/init/scripts/render_agents.py" --roster "$project_roster" --templates "$plugin/templates/agents" --out "$out" >/dev/null || die "could not render $project_roster"
    for f in "$out"/claude/*.md; do [ -f "$f" ] && install_file "$f" ".claude/agents/$(basename "$f")"; done
    for f in "$out"/codex/*.toml; do [ -f "$f" ] && install_file "$f" ".codex/agents/$(basename "$f")"; done
  fi
fi
# A rendered agent the roster dropped: stamped, no longer written, removed when still what init
# wrote.
for old in $(awk -F'\t' 'NR > 1 && ($2 ~ /^\.claude\/agents\// || $2 ~ /^\.codex\/agents\//) { print $2 }' "$stamp" 2>/dev/null); do
  case " $stamped $kept " in *" $old "*) continue ;; esac
  [ -f "$old" ] || continue
  if [ "$check" -eq 1 ]; then drifted "stale: $old (no longer in the roster)"
  elif [ "$(stamp_get "$stamp" "$old")" = "$(hash_file "$old")" ]; then rm -f "$old" && note "$old removed (no longer in the roster)"
  else echo "init: $old is no longer in the roster but was edited by hand; delete it yourself"; fi
done

# 10. Gaps: the values the hooks and the verifier cannot run without, and the guide's
# placeholders. Reported every run; drift under --check. The init skill fills them with the
# owner (the project-advisor agent recommends the values from the repository).
if [ -f .standards/config.json ]; then
  gap_lines="$(python3 - <<'PY'
import json
try: c = json.load(open(".standards/config.json"))
except Exception as e: print(".standards/config.json does not parse: %s" % e); raise SystemExit
for k in ("build", "test"):
    if not c.get(k): print(".standards/config.json: %s is empty; the %s" % (k, "pre-push hook and verify run it" if k == "build" else "verifier runs it"))
langs = c.get("languages") or []
if not langs: print(".standards/config.json: languages is empty; the formatter and the comment hooks check nothing")
for i, l in enumerate(langs):
    if not l.get("format"): print(".standards/config.json: languages[%d] (%s) has no format command" % (i, l.get("name", "?")))
    if not l.get("extensions"): print(".standards/config.json: languages[%d] (%s) has no extensions" % (i, l.get("name", "?")))
try: lines = open(".standards/testing-guide.md").read().splitlines()
except OSError: lines = []
holes = [n for n, t in enumerate(lines, 1) if "_fill in" in t]
if holes: print(".standards/testing-guide.md: %d placeholder(s) left (line%s %s)" % (len(holes), "s" if len(holes) > 1 else "", ", ".join(map(str, holes))))
PY
)"
  while IFS= read -r line; do [ -n "$line" ] && gap "$line"; done <<EOF
$gap_lines
EOF
fi

if [ "$check" -eq 1 ]; then
  [ "$drift" -eq 0 ] && echo "init: up to date with standards v$version"
  exit "$drift"
fi
write_stamp
if [ "$refused" -eq 1 ]; then echo "standards v$version: some copies were refused (see above); the rest is installed."; else echo "standards v$version installed."; fi
[ -n "$changed" ] && { echo "Changed:"; printf '%s' "$changed"; }
[ -n "$gaps" ] && { echo "Gaps (the hooks and the verifier need these; init --check reports them until filled):"; printf '%s' "$gaps"; }
echo "Next:"
echo "  - review .standards/config.json (format, build, test and mutation commands, protected files, hot paths)"
echo "  - fill in .standards/testing-guide.md (fixtures, declared exceptions, what you test by hand)"
echo "  - commit the changes with [config] in the message: .standards/ and .githooks/ are protected files"
echo "  - every clone sets the git hooks path once: git config core.hooksPath $wanted (init does it here)"
echo "  - Codex: the plugin hooks need a one-time trust. Run /hooks in Codex once, and again after a plugin update."
echo "  - CI: one step runs the commit gates per commit: uses: FilipposKaragiannis/brain/plugins/standards/action@main (after a checkout with fetch-depth: 0 and the toolchain setup)"
for tool in jq python3; do command -v "$tool" >/dev/null 2>&1 || echo "  - $tool is not installed; the hooks need jq or python3"; done
cfg_json="$(cat .standards/config.json)"; n="$(json_length "$cfg_json" languages)"; i=0
while [ "$i" -lt "$n" ]; do
  if [ -n "$(json_get "$cfg_json" "languages.$i.comments.doc")" ] && [ -z "$(json_get "$cfg_json" "languages.$i.comments.doc_inside")" ]; then
    echo "  - languages[$i] ($(json_get "$cfg_json" "languages.$i.name")) has no comments.doc_inside: the hook assumes [\"interface\", \"enum\"]. Add the key to change it."
  fi
  i=$((i + 1))
done
exit "$refused"
