#!/bin/sh
# Lint the marketplace: generated files fresh, skills well-formed, roster and agents in step,
# JSON valid, shell scripts parse, hooks and plugin paths resolve. Exit 1 on any finding.
set -u
cd "$(dirname "$0")/.."
status=0
fail() { echo "lint: $1"; status=1; }

python3 tools/lib/generate.py --check || status=1

for f in $(find . -name '*.json' -not -path './.git/*' -not -path '*/node_modules/*'); do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || fail "invalid JSON: $f"
done

# node_modules and ui/dist are the console app's installed and built files, not ours to lint.
for f in $(find tools plugins shared -name '*.sh' -not -path '*/node_modules/*' -not -path '*/dist/*') plugins/*/hooks/git/*; do
  [ -f "$f" ] || continue
  sh -n "$f" || fail "shell syntax: $f"
done
for f in $(find tools plugins -name '*.py' -not -path '*/evals/results/*' -not -path '*/node_modules/*'); do
  python3 -m py_compile "$f" 2>/dev/null || fail "python syntax: $f"
done
rm -rf tools/lib/__pycache__ plugins/*/*/__pycache__ plugins/*/*/*/__pycache__

# Every skill has a SKILL.md whose name matches its directory and that has a description.
for skill_dir in plugins/*/skills/*/; do
  case "$(basename "$skill_dir")" in _*) continue ;; esac
  skill="$(basename "$skill_dir")"
  md="$skill_dir/SKILL.md"
  [ -f "$md" ] || { fail "missing SKILL.md: $skill_dir"; continue; }
  head -1 "$md" | grep -q '^---$' || fail "no frontmatter: $md"
  grep -q "^name: $skill\$" "$md" || fail "frontmatter name is not '$skill': $md"
  grep -q '^description:' "$md" || fail "no description: $md"
done

# Committed symlinks are relative and resolve inside the repo. GitHub Actions downloads this
# repo to run plugins/standards/action, and an absolute or dangling link fails "Set up job".
root="$(pwd -P)"
for link in $(git ls-files -s | awk '$1 == "120000" { print $4 }'); do
  target="$(readlink "$link")"
  case "$target" in
    /*) fail "absolute symlink: $link -> $target"; continue ;;
  esac
  [ -e "$link" ] || { fail "dangling symlink: $link -> $target"; continue; }
  resolved="$(cd "$(dirname "$link")" && cd "$(dirname "$target")" && pwd -P)"
  case "$resolved/" in
    "$root"/*) ;;
    *) fail "symlink leaves the repo: $link -> $target" ;;
  esac
done

# Relative links in plugin Markdown resolve and stay inside the plugin (plugins install apart).
python3 - <<'PY2' || status=1
import glob, os, re, sys
bad = 0
for md in glob.glob("plugins/*/**/*.md", recursive=True):
    if "/evals/results/" in md or "/node_modules/" in md or "/dist/" in md:
        continue
    plugin = os.path.normpath(md).split(os.sep)[1]
    for target in re.findall(r"\]\(([^)#\s]+\.md)(?:#[^)]*)?\)", open(md, encoding="utf-8").read()):
        if "://" in target or target.startswith("/"):
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(md), target))
        if not os.path.exists(resolved):
            print("lint: broken link in %s: %s" % (md, target)); bad += 1
        elif resolved.split(os.sep)[:2] != ["plugins", plugin]:
            print("lint: link leaves the plugin in %s: %s" % (md, target)); bad += 1
sys.exit(1 if bad else 0)
PY2

# Hook commands name executable scripts in the plugin; plugin paths the shipped files name exist.
python3 tools/lib/check_plugins.py || status=1

# The invocation flag in plugin.source.json matches the SKILL.md frontmatter.
python3 - <<'PY' || status=1
import glob, json, re, sys
bad = 0
for src in glob.glob("plugins/*/plugin.source.json"):
    plugin = json.load(open(src))
    pdir = src.rsplit("/", 1)[0]
    listed = {s["name"] for s in plugin["skills"]}
    on_disk = {p.split("/")[-2] for p in glob.glob(pdir + "/skills/*/SKILL.md")}
    for name in sorted(on_disk - listed):
        print("lint: skill on disk but not in %s: %s" % (src, name)); bad += 1
    for name in sorted(listed - on_disk):
        print("lint: skill listed in %s but missing on disk: %s" % (src, name)); bad += 1
    for skill in plugin["skills"]:
        if skill["invocation"] not in ("user", "model"):
            print("lint: %s: invocation must be user or model: %s" % (src, skill["name"])); bad += 1
            continue
        md = "%s/skills/%s/SKILL.md" % (pdir, skill["name"])
        try:
            head = open(md).read().split("\n---", 2)[0]
        except OSError:
            continue
        flagged = re.search(r"^disable-model-invocation:\s*true", head, re.M) is not None
        if flagged != (skill["invocation"] == "user"):
            print("lint: %s: invocation '%s' but disable-model-invocation is %s" % (md, skill["invocation"], flagged)); bad += 1
sys.exit(1 if bad else 0)
PY

# Roster: every agent has a brief, model and tier are known, no agent file without a roster entry.
python3 - <<'PY' || status=1
import glob, json, os, sys
r = json.load(open("roster/agents.json"))
bad = 0
for name, a in r["agents"].items():
    brief = a.get("brief", "roster/briefs/%s.md" % name)
    if not os.path.exists(brief):
        print("lint: roster agent %s has no brief at %s" % (name, brief)); bad += 1
    if a["model"] not in r["model_map"]:
        print("lint: roster agent %s: unknown model %s" % (name, a["model"])); bad += 1
    if a["tier"] not in r["tiers"]:
        print("lint: roster agent %s: unknown tier %s" % (name, a["tier"])); bad += 1
    if a["effort"] not in ("low", "medium", "high", "xhigh", "max"):
        print("lint: roster agent %s: unknown effort %s" % (name, a["effort"])); bad += 1
    if not os.path.exists("plugins/%s/plugin.source.json" % a["plugin"]):
        print("lint: roster agent %s: unknown plugin %s" % (name, a["plugin"])); bad += 1
for path in glob.glob("plugins/*/agents/*.md") + glob.glob("plugins/*/codex-agents/*.toml"):
    name = os.path.splitext(os.path.basename(path))[0]
    if name not in r["agents"]:
        print("lint: agent file without a roster entry: %s" % path); bad += 1
for path in glob.glob("roster/briefs/*.md"):
    name = os.path.splitext(os.path.basename(path))[0]
    if name not in r["agents"]:
        print("lint: brief without a roster entry: %s" % path); bad += 1
sys.exit(1 if bad else 0)
PY

# The installed block must stay under 6 KB (Codex budget).
size="$(wc -c < plugins/standards/rules/block.md | tr -d ' ')"
[ "$size" -le 6144 ] || fail "standards block is $size bytes, limit 6144"

[ "$status" -eq 0 ] && echo "lint: ok"
exit $status
