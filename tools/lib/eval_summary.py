"""Score an eval run without its infrastructure failures.

`claude plugin eval` averages a run that errored before the agent could work (not logged in, a
rate limit, a crashed child) into the case score as a 0. This reads an aggregate-result.json and
prints each case's score and pass count over the scored runs only, with the BLOCKED runs counted
apart. A run that hit max_turns or its timeout is the skill's own failure and stays scored. A
run whose judge evidence shows the sandbox broke a tool (git through xcrun failing to write its
cache) is BLOCKED too: the skill could not start its work.

    python3 tools/lib/eval_summary.py <aggregate-result.json | results dir> [--save | --against <file>]

A directory holding run directories resolves to the newest aggregate-result.json under it. Each
case line ends with the score in the baseline file (tools/eval-baseline.json, or --against) and
the change from it. --save writes this result's scores into the baseline file instead, under the
plugin's name, replacing the cases and arms it ran and keeping the rest.
"""
import glob
import json
import os
import re
import subprocess
import sys
from datetime import date

# Errors the agent caused: these runs keep their score. The CLI words the case timeout
# "timed out after <timeout_seconds>s"; a network timeout reads differently and is BLOCKED.
AGENT_ERRORS = re.compile(r"Reached maximum number of turns|^timed out after \d+s")
# The sandbox breaking a tool before the skill could use it, as the agent quotes it.
SANDBOX_ERRORS = re.compile(r"Failed to locate '[\w.-]+'")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = os.environ.get("EVAL_BASELINE") or os.path.join(ROOT, "tools", "eval-baseline.json")


def resolve(path):
    if os.path.isfile(path):
        return path
    direct = os.path.join(path, "aggregate-result.json")
    if os.path.isfile(direct):
        return direct
    found = glob.glob(os.path.join(path, "*", "aggregate-result.json"))
    return max(found, key=os.path.getmtime) if found else None


def blocked(run):
    error = run.get("error") or ""
    if error:
        return not AGENT_ERRORS.search(error)
    return any(SANDBOX_ERRORS.search(g.get("evidence") or "") for g in run.get("graders") or [])


def reason(run):
    error = run.get("error") or ""
    if error:
        return error.splitlines()[0][:60]
    for grader in run.get("graders") or []:
        found = SANDBOX_ERRORS.search(grader.get("evidence") or "")
        if found:
            return "sandbox: " + found.group(0)
    return "unknown"


def plugin_name(result, path):
    plugins = (result.get("suite") or {}).get("plugins") or []
    if plugins and plugins[0].get("name"):
        return plugins[0]["name"]
    found = re.search(r"plugins/([^/]+)/evals/", os.path.abspath(path))
    return found.group(1) if found else "unknown"


def scores(result):
    """{case: {arm: {score, passed, runs}}} over the scored runs."""
    out = {}
    for case in result.get("cases", []):
        for arm, runs in (case.get("arms") or {}).items():
            scored = [r for r in runs or [] if not blocked(r)]
            if scored:
                out.setdefault(case["name"], {})[arm] = {
                    "score": round(sum(r.get("score", 0) for r in scored) / len(scored), 2),
                    "passed": sum(1 for r in scored if r.get("passed")),
                    "runs": len(scored)}
    return out


def load(path):
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(result, plugin, path):
    data = load(path)
    cases = data.setdefault("plugins", {}).setdefault(plugin, {})
    for name, arms in scores(result).items():
        cases.setdefault(name, {}).update(arms)
    data["recorded"] = date.today().isoformat()
    try:
        data["commit"] = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                                        capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        pass
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def summarise(result, baseline=None):
    baseline = baseline or {}
    lines = []
    scored_total, blocked_total, cases_passed, cases_scored = 0, 0, 0, 0
    for case in result.get("cases", []):
        for arm, runs in sorted((case.get("arms") or {}).items()):
            if not runs:
                continue
            scored = [r for r in runs if not blocked(r)]
            stopped = [r for r in runs if blocked(r)]
            scored_total += len(scored)
            blocked_total += len(stopped)
            label = "%s [%s]" % (case["name"], arm)
            if scored:
                score = sum(r.get("score", 0) for r in scored) / len(scored)
                passed = sum(1 for r in scored if r.get("passed"))
                line = "  %-44s score %.2f, passed %d/%d" % (label, score, passed, len(scored))
                before = (baseline.get(case["name"]) or {}).get(arm)
                if before:
                    line += " (baseline %.2f, %+.2f)" % (before["score"], round(score, 2) - before["score"])
                if arm == "with":
                    cases_scored += 1
                    cases_passed += passed == len(scored)
            else:
                line = "  %-44s no scored run" % label
            if stopped:
                reasons = sorted({reason(r) for r in stopped})
                line += ", BLOCKED %d (%s)" % (len(stopped), "; ".join(reasons))
            lines.append(line)
    lines.append("  cases passed %d/%d over scored runs; %d runs scored, %d BLOCKED"
                 % (cases_passed, cases_scored, scored_total, blocked_total))
    return lines


def main(argv):
    args, mode, against = argv[1:], None, BASELINE
    if len(args) == 2 and args[1] == "--save":
        mode = "save"
    elif len(args) == 3 and args[1] == "--against":
        against = args[2]
    elif len(args) != 1:
        print("usage: eval_summary.py <aggregate-result.json | results dir> [--save | --against <file>]",
              file=sys.stderr)
        return 2
    path = resolve(args[0])
    if not path:
        print("eval summary: no aggregate-result.json under %s" % args[0])
        return 1
    with open(path, encoding="utf-8") as f:
        result = json.load(f)
    plugin = plugin_name(result, path)
    if mode == "save":
        save(result, plugin, BASELINE)
        print("eval summary: saved %s scores to %s" % (plugin, BASELINE))
        return 0
    print("eval summary (BLOCKED runs left out of the score): %s" % path)
    for line in summarise(result, load(against).get("plugins", {}).get(plugin)):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
