"""One Jira REST call through curl, tried again on a 5xx answer or a dropped connection: the waits
of gh() in lib/flow.sh (FLOW_JIRA_RETRY_WAIT, default "2 5", a try after each), and any other
failure is final at once. A call that creates something (an issue, a comment, a link, a
transition) is tried once: a lost answer can follow a write that landed. The login and the token
reach curl on its stdin (-K -), never on its command line, where any process could read them."""
import json
import os
import subprocess
import sys
import tempfile
import time

# curl's exits for a connection that failed or dropped: cannot resolve, cannot connect, timed out,
# TLS handshake, empty reply, send failed, receive failed.
NETWORK_FAILURES = {6, 7, 28, 35, 52, 55, 56}
SERVER_ERROR = 500


def fail(message, code=1):
    sys.stderr.write("flow: %s\n" % message)
    sys.exit(code)


def curl_config_value(text):
    return '"%s"' % text.replace("\\", "\\\\").replace('"', '\\"')


def call(method, path, body=None, query=None, once=False):
    """(status, decoded JSON) of one call; status 0 when no answer came."""
    from urllib.parse import urlencode
    url = os.environ["FLOW_JIRA_SITE"].rstrip("/") + path + ("?" + urlencode(query) if query else "")
    login = "user = %s\n" % curl_config_value("%s:%s" % (os.environ["FLOW_JIRA_EMAIL"], os.environ["JIRA_API_TOKEN"]))
    args = ["curl", "-sS", "-K", "-", "-X", method, "-H", "Accept: application/json", "-w", "\n%{http_code}"]
    body_file = None
    if body is not None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as body_file:
            json.dump(body, body_file)
        args += ["-H", "Content-Type: application/json", "--data-binary", "@" + body_file.name]
    waits = [] if once else (os.environ.get("FLOW_JIRA_RETRY_WAIT") or "2 5").split()
    try:
        for wait in waits + [None]:
            out = subprocess.run(args + [url], input=login, capture_output=True, text=True)
            text, _, code = out.stdout.rpartition("\n")
            status = int(code) if code.isdigit() else 0
            if wait is None or not (out.returncode in NETWORK_FAILURES or status >= SERVER_ERROR):
                break
            sys.stderr.write("flow: jira: %s %s answered %s; trying again in %ss\n" % (method, path, status or "nothing", wait))
            time.sleep(float(wait))
    finally:
        if body_file:
            os.unlink(body_file.name)
    if not status:
        fail("jira: %s %s: %s" % (method, path, out.stderr.strip() or "no answer"))
    try:
        return status, json.loads(text) if text.strip() else {}
    except ValueError:
        return status, {"errorMessages": [text.strip()[:200]]}


def expect(status, answer, what):
    if status // 100 == 2:
        return
    words = list((answer or {}).get("errorMessages") or []) + ["%s: %s" % kv for kv in ((answer or {}).get("errors") or {}).items()]
    fail("cannot %s: Jira answered %d%s" % (what, status, (": " + "; ".join(words)) if words else ""))
