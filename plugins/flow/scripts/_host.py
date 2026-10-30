"""What one host session said, read back from its output. See host_run in lib/host.sh.

  _host.py <claude|codex> <stdout file> <stderr file> <exit code> <summary file>

Claude runs with --output-format json: stdout is one result object. Codex runs with --json:
stdout is one event per line. Prints the text the session would have printed without those
flags (Claude's result, Codex's agent messages; a line that is not the host's JSON passes as it
is), Codex's errors to stderr, and writes the summary file: one JSON object with the usage the
host reported (Claude's usage block as given, the sum of Codex's turn usage), the cost when the
host reports one, the models that ran, and the cause when a failed session stopped on a spend
limit or an auth error, with the host's line that says so. Only a failed session has a cause:
a session that ended well may quote those lines."""
import json, re, sys

# The host's own words for a limit on spend and for a login that does not work, from the claude
# and codex binaries: the Claude subscription and credit limits, the API's budget answer, Codex's
# usage limit and quota; the logins that expired, were revoked or are missing.
SPEND = re.compile(r"credit balance is too low|out of extra usage|requires usage credits|seat type doesn.t include"
                   r"|usage allocation has been disabled|usage limit|spend limit|spending limit|ExceededBudget"
                   r"|hit your limit|quota exceeded|insufficient_quota|credits_depleted|spend_control_reached"
                   r"|purchase more credits", re.I)
AUTH = re.compile(r"please run /login|not logged in|invalid api key|invalid auth token|oauth token (revoked|has expired)"
                  r"|login expired|session expired|authentication required|authentication_error|disabled api key authentication"
                  r"|401 unauthorized|unexpected status 401|refresh token was rejected|token refresh failed"
                  r"|auth is missing|failed to refresh token", re.I)


def objects(text):
    """Each line as (the JSON object, None) or (None, the line)."""
    for line in text.splitlines():
        try:
            v = json.loads(line)
        except ValueError:
            v = None
        yield (v, None) if isinstance(v, dict) else (None, line)


def claude(out, said):
    text, usage, cost, models, failed = [], None, None, [], False
    try:
        whole = json.loads(out)
    except ValueError:
        whole = None
    pairs = [(whole, None)] if isinstance(whole, dict) else objects(out)
    for obj, line in pairs:
        if obj is None or obj.get("type") != "result":
            text.append(line if obj is None else json.dumps(obj))
            continue
        result = obj.get("result")
        if isinstance(result, str):
            text.append(result)
        if obj.get("is_error"):
            failed = True
            said.append(str(result or obj.get("subtype") or ""))
        usage = obj.get("usage") if isinstance(obj.get("usage"), dict) else None
        cost = obj.get("total_cost_usd")
        models = sorted(obj["modelUsage"]) if isinstance(obj.get("modelUsage"), dict) else []
    return text, usage, cost, models, failed


def codex(out, said):
    text, usage, models, failed = [], None, [], False
    for obj, line in objects(out):
        if obj is None:
            text.append(line)
            continue
        kind = obj.get("type")
        item = obj.get("item") if isinstance(obj.get("item"), dict) else {}
        if kind == "item.completed" and item.get("type") == "agent_message" and isinstance(item.get("text"), str):
            text.append(item["text"])
        elif kind in ("error", "turn.failed"):
            err = obj.get("error") if isinstance(obj.get("error"), dict) else obj
            message = str(err.get("message") or "")
            failed = True
            said.append(message)
            print(message, file=sys.stderr)
        elif kind == "turn.completed" and isinstance(obj.get("usage"), dict):
            usage = usage or {}
            for k, v in obj["usage"].items():
                if isinstance(v, int):
                    usage[k] = usage.get(k, 0) + v
        if isinstance(obj.get("model"), str) and obj["model"] not in models:
            models.append(obj["model"])
    return text, usage, None, models, failed


def cause(lines):
    """spend-limit or auth, and the line that says so; the spend limit wins when both show."""
    for name, pattern in (("spend-limit", SPEND), ("auth", AUTH)):
        for line in lines:
            if pattern.search(line):
                return name, line.strip()[:300]
    return "", ""


def main():
    host, out_path, err_path, code, summary_path = sys.argv[1:6]
    out = open(out_path, encoding="utf-8", errors="replace").read()
    err = open(err_path, encoding="utf-8", errors="replace").read()
    said = []
    text, usage, cost, models, failed = (claude if host == "claude" else codex)(out, said)
    if text:
        print("\n".join(text))
    found = ("", "")
    if failed or code != "0":
        # The host's error, then the tail of what it printed: the last words name the stop.
        lines = [l for s in said for l in s.splitlines()] + err.splitlines()[-40:] + [l for l in text if l][-20:]
        found = cause(lines)
    summary = {"usage": usage, "cost_usd": cost if isinstance(cost, (int, float)) else None,
               "models": models, "cause": found[0], "said": found[1]}
    with open(summary_path, "w") as f:
        json.dump(summary, f)


if __name__ == "__main__":
    main()
