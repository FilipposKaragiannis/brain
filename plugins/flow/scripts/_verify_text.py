"""Turns raw output into one clean line of text, or into a line that keeps its spacing and tabs but
loses terminal colours, links and other control characters. See scripts/_verify_report.py."""
import re

_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\|$)")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_CONTROL_BUT_TAB = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")


def text(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace")


def one_line(value: str) -> str:
    return " ".join(_CONTROL.sub(" ", _ANSI.sub("", _OSC.sub("", value))).split())


def holds_control_character(value: str) -> bool:
    return _CONTROL.search(value) is not None


def terminal_free(value: str) -> str:
    return _CONTROL_BUT_TAB.sub("", _ANSI.sub("", _OSC.sub("", value)))
