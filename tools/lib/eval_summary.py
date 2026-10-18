"""Score an eval run without its infrastructure failures.

`claude plugin eval` averages a run that errored before the agent could work (not logged in, a
rate limit, a crashed child) into the case score as a 0. This reads an aggregate-result.json and
prints each case's score and pass count over the scored runs only, with the BLOCKED runs counted
apart. A run that hit max_turns or its timeout is the skill's own failure and stays scored.

    python3 tools/lib/eval_summary.py <aggregate-result.json | results dir | plugin results root>

A directory holding run directories resolves to the newest aggregate-result.json under it.
"""
import glob
import json
import os
import re
import sys

# Errors the agent caused: these runs keep their score. The CLI words the case timeout
# "timed out after <timeout_seconds>s"; a network timeout reads differently and is BLOCKED.
AGENT_ERRORS = re.compile(r"Reached maximum number of turns|^timed out after \d+s")


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
    return bool(error) and not AGENT_ERRORS.search(error)


def summarise(result):
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
                if arm == "with":
                    cases_scored += 1
                    cases_passed += passed == len(scored)
            else:
                line = "  %-44s no scored run" % label
            if stopped:
                reasons = sorted({(r.get("error") or "").splitlines()[0][:60] for r in stopped})
                line += ", BLOCKED %d (%s)" % (len(stopped), "; ".join(reasons))
            lines.append(line)
    lines.append("  cases passed %d/%d over scored runs; %d runs scored, %d BLOCKED"
                 % (cases_passed, cases_scored, scored_total, blocked_total))
    return lines


def main(argv):
    if len(argv) != 2:
        print("usage: eval_summary.py <aggregate-result.json | results dir>", file=sys.stderr)
        return 2
    path = resolve(argv[1])
    if not path:
        print("eval summary: no aggregate-result.json under %s" % argv[1])
        return 1
    with open(path, encoding="utf-8") as f:
        result = json.load(f)
    print("eval summary (BLOCKED runs left out of the score): %s" % path)
    for line in summarise(result):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
