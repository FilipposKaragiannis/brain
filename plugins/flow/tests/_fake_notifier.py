"""A fake desktop notification centre for the notify tests: osascript and notify-send in one file.
It shows a notification only when the command is one the real tool would act on, and appends what
the owner would see to the file named by FAKE_NOTIFICATIONS."""
import json, os, re, sys

DISPLAY_LINE = re.compile(r"^display notification \(item (\d+) of argv\) with title \(item (\d+) of argv\) subtitle \(item (\d+) of argv\)$")


def show(tool, title, subtitle, body):
    with open(os.environ["FAKE_NOTIFICATIONS"], "a") as shown:
        shown.write(json.dumps({"tool": tool, "title": title, "subtitle": subtitle, "body": body}) + "\n")


def osascript(arguments):
    script, position = [], 0
    while position < len(arguments) and arguments[position] == "-e":
        script.append(arguments[position + 1]); position += 2
    if arguments[position:position + 1] == ["--"]: position += 1
    argv = arguments[position:]
    if len(script) != 3 or script[0] != "on run argv" or script[2] != "end run": return 1
    display = DISPLAY_LINE.match(script[1])
    if not display: return 1
    body, title, subtitle = (int(index) for index in display.groups())
    if max(body, title, subtitle) > len(argv): return 1
    show("osascript", argv[title - 1], argv[subtitle - 1], argv[body - 1])
    return 0


def notify_send(arguments):
    if arguments[:1] == ["--"]: arguments = arguments[1:]
    elif arguments and arguments[0].startswith("-"): return 1
    if len(arguments) != 2: return 1
    show("notify-send", arguments[0], "", arguments[1])
    return 0


tool, arguments = sys.argv[1], sys.argv[2:]
sys.exit(osascript(arguments) if tool == "osascript" else notify_send(arguments))
