#!/bin/sh
# scaffold.sh <plugin dir> <skill name> [--user] [--display "Name"] [--short "one line"]
# Creates skills/<name>/SKILL.md, evals/<name>-works/{case.yaml,prompt.md,graders/}, and the
# entry in plugin.source.json when the plugin has one (this marketplace). POSIX sh + python3.
set -u
plugin="${1:?plugin directory}"; name="${2:?skill name}"; shift 2
invocation="model"; display=""; short=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) invocation="user"; shift ;;
    --display) display="$2"; shift 2 ;;
    --short) short="$2"; shift 2 ;;
    *) echo "scaffold: unknown option $1" >&2; exit 2 ;;
  esac
done
case "$name" in *[!a-z0-9-]*|'') echo "scaffold: skill names are lowercase letters, digits and dashes" >&2; exit 2 ;; esac
[ -d "$plugin" ] || { echo "scaffold: no such directory $plugin" >&2; exit 2; }
dir="$plugin/skills/$name"
[ -e "$dir" ] && { echo "scaffold: $dir exists" >&2; exit 1; }
[ -n "$display" ] || display="$(printf '%s' "$name" | sed 's/-/ /g; s/\b\(.\)/\u\1/g' 2>/dev/null || printf '%s' "$name")"
[ -n "$short" ] || short="What $name does, in one line"
mkdir -p "$dir" "$plugin/evals/$name-works/graders"
if [ "$invocation" = "user" ]; then flag="disable-model-invocation: true
"; desc="$short."; else flag=""; desc="$short. Use when the user asks to <trigger>, mentions <leading word>, or when another skill needs <reach clause>."; fi
cat > "$dir/SKILL.md" <<MD
---
name: $name
description: $desc
$flag---

<One sentence: what this skill produces and for whom.>

## Steps

1. **<Step>.** <What to do.> Done when <checkable completion criterion>.
2. **<Step>.** ...

## Reference

<Rules and facts consulted on demand. Push long reference to a sibling file and link it by
relative path inside this skill folder.>

## Never

- <The one hard guardrail, phrased with what to do instead.>
MD
cat > "$plugin/evals/$name-works/case.yaml" <<YAML
schema_version: "1.1"
name: $name-works
runs: 3
execution:
  max_turns: 15
  timeout_seconds: 600
  allowed_tools:
    - Bash
    - Read
    - Glob
    - Grep
context:
  scaffold_script: scaffold.sh
YAML
printf '#!/bin/sh\n# Fixture for the %s eval. Runs as you, in a fresh sandbox directory.\nset -e\ngit init -q .\ngit config user.email eval@example.com\ngit config user.name eval\nprintf "# Fixture\\n" > README.md\ngit add -A && git commit -qm init\n' "$name" > "$plugin/evals/$name-works/scaffold.sh"
chmod +x "$plugin/evals/$name-works/scaffold.sh"
if [ "$invocation" = "user" ]; then printf '/%s:%s\n' "$(basename "$plugin")" "$name" > "$plugin/evals/$name-works/prompt.md"
else printf '<A user message that should trigger %s without naming it.>\n' "$name" > "$plugin/evals/$name-works/prompt.md"; fi
printf -- '---\ntype: tool_used\ntool: Skill\ninput_match: %s\narm: with-only\n---\n' "'\"skill\"\\s*:\\s*\"(?:[\\w-]+:)?$name\"'" > "$plugin/evals/$name-works/graders/uses-skill.md"
printf -- '---\ntype: llm\n---\nThe final message <states the outcome the skill promises>, reports once, and does not narrate step by step.\n' > "$plugin/evals/$name-works/graders/reports-once.md"
if [ -f "$plugin/plugin.source.json" ]; then
  python3 - "$plugin/plugin.source.json" "$name" "$invocation" "$display" "$short" <<'PY'
import json, sys
p, name, inv, display, short = sys.argv[1:6]
d = json.load(open(p))
if not any(s["name"] == name for s in d.get("skills", [])):
    d.setdefault("skills", []).append({"name": name, "invocation": inv, "displayName": display, "shortDescription": short,
                                       "defaultPrompt": "Use $%s to %s." % (name, short[0].lower() + short[1:])})
    json.dump(d, open(p, "w"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
PY
  echo "added $name to $plugin/plugin.source.json; run tools/generate.sh"
fi
echo "scaffolded $dir and $plugin/evals/$name-works"
echo "next: fill SKILL.md, write the eval prompt and graders, run tools/lint.sh"
