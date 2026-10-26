"""One gh call, tried again on a 5xx answer or a dropped connection: the Python side of the gh()
in lib/flow.sh, with the same waits (FLOW_GH_RETRY_WAIT, default "2 5") and the same test of
what counts as a blip. Any other failure is final at once. The calls here read, or write a
value a second write leaves as it is; nothing is created, so a second try is safe."""
import os, re, subprocess, sys, time

# The same pattern as lib/flow.sh's gh_blip; change both.
BLIP = re.compile(r"HTTP 5[0-9][0-9]|connection reset|connection refused|error connecting|timeout|unexpected EOF|: EOF$|stream error|GOAWAY|temporarily unavailable", re.I | re.M)


def gh(args, stdin=None):
    """subprocess.run(["gh", *args]) with stdout and stderr captured, after the retries."""
    waits = (os.environ.get("FLOW_GH_RETRY_WAIT") or "2 5").split()
    for wait in waits + [None]:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, input=stdin)
        if out.returncode == 0 or wait is None or not BLIP.search(out.stderr):
            return out
        first = out.stderr.strip().splitlines()[0] if out.stderr.strip() else "no answer"
        sys.stderr.write("flow: gh: %s; trying again in %ss\n" % (first, wait))
        try:
            time.sleep(float(wait))
        except ValueError:
            pass
    return out
