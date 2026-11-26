"""The flow's state comment on a GitHub issue: a comment that starts with the marker and that a
login trusted_logins in _gh.sh names wrote. Anyone can comment on a public issue, so a marker
comment by anyone else is never read as state, nor deleted. _query.py reads the same rule.

  _state_comment.py first <marker> <logins>   the first one, {"id", "data"}; id null when none
  _state_comment.py ids <marker> <logins>     the id of every one, one per line

Both read the comment pages (gh api --paginate --slurp) on stdin; logins are comma-separated."""
import dataclasses
import json
import re
import sys

FENCED_STATE = re.compile(r"```json\n(.*?)\n```", re.S)
USAGE_REFUSED = 2


@dataclasses.dataclass(frozen=True)
class StateCommentRule:
    marker: str
    logins: frozenset


def rule_of(marker: str, logins: str) -> StateCommentRule:
    return StateCommentRule(marker, frozenset(login for login in logins.split(",") if login))


def holds_state(rule: StateCommentRule, comment: dict) -> bool:
    author = (comment.get("user") or {}).get("login")
    return (comment.get("body") or "").startswith(rule.marker) and author in rule.logins


def state_of(comment: dict) -> dict:
    fenced = FENCED_STATE.search(comment["body"])
    if not fenced:
        return {}
    try:
        return json.loads(fenced.group(1))
    except ValueError:
        return {}


def state_comments(rule: StateCommentRule, pages: list) -> list:
    return [comment for page in pages for comment in page if holds_state(rule, comment)]


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[1] not in ("first", "ids"):
        sys.stderr.write("usage: _state_comment.py <first|ids> <marker> <logins>\n")
        sys.exit(USAGE_REFUSED)
    found = state_comments(rule_of(sys.argv[2], sys.argv[3]), json.load(sys.stdin))
    if sys.argv[1] == "ids":
        print("\n".join(str(comment["id"]) for comment in found))
        return
    first = found[0] if found else None
    print(json.dumps({"id": first["id"], "data": state_of(first)} if first else {"id": None, "data": {}}))


if __name__ == "__main__":
    main()
