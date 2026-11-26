"""The verify report as typed values, for scripts/_pr_report.py.

read_report parses <reports dir>/verify.json at the boundary: every field the section prints has
the type the section needs, or the result carries a problem naming the folder and the field and
no report. A proof keeps the one detail its grade shows: the evidence file of a live proof, the
test of a test proof, the reason of an error.
"""
import json
import os
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Callable, Mapping, Optional, Tuple

from _verify_proofs import GRADE_ERROR, GRADE_LIVE, GRADE_TEST

REPORT_FILE = "verify.json"
TEXT_ENCODING = "utf-8"
REQUIRED_KEYS = ("verdict", "proven", "acceptance_lines", "proofs", "not_checked")
ENTRY_KEYS = ("line", "text", "grade")
REASON_KEY = "reason"
NO_DETAIL = ""
GRADE_DETAIL_KEYS: Mapping[str, str] = MappingProxyType({
    GRADE_LIVE: "evidence",
    GRADE_TEST: "test",
    GRADE_ERROR: REASON_KEY,
})


@dataclass(frozen=True)
class Proof:
    line: Optional[int]
    text: str
    grade: str
    detail: str


@dataclass(frozen=True)
class NotChecked:
    line: Optional[int]
    text: str
    grade: str
    reason: str


@dataclass(frozen=True)
class VerifyReport:
    verdict: str
    proven: int
    acceptance_lines: int
    proofs: Tuple[Proof, ...]
    not_checked: Tuple[NotChecked, ...]


@dataclass(frozen=True)
class ReadReport:
    report: VerifyReport
    problem: str


EMPTY_REPORT = VerifyReport(verdict="", proven=0, acceptance_lines=0, proofs=(), not_checked=())


def is_whole_number(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def has_entry_shape(entry: Any) -> bool:
    return (isinstance(entry, dict) and all(key in entry for key in ENTRY_KEYS)
            and (entry["line"] is None or is_whole_number(entry["line"]))
            and isinstance(entry["text"], str) and isinstance(entry["grade"], str))


def parsed_proof(entry: Any) -> Optional[Proof]:
    if not has_entry_shape(entry):
        return None
    detail_key = GRADE_DETAIL_KEYS.get(entry["grade"])
    detail = entry.get(detail_key) if detail_key else NO_DETAIL
    if not isinstance(detail, str):
        return None
    return Proof(line=entry["line"], text=entry["text"], grade=entry["grade"], detail=detail)


def parsed_not_checked(entry: Any) -> Optional[NotChecked]:
    if not has_entry_shape(entry) or not isinstance(entry.get(REASON_KEY), str):
        return None
    return NotChecked(line=entry["line"], text=entry["text"], grade=entry["grade"], reason=entry[REASON_KEY])


def parsed_entries(values: Any, parse: Callable[[Any], Optional[Any]]) -> Optional[Tuple[Any, ...]]:
    if not isinstance(values, list):
        return None
    entries = tuple(parse(value) for value in values)
    return None if any(entry is None for entry in entries) else entries


def malformed_key(document: dict) -> str:
    checks = (("verdict", isinstance(document["verdict"], str)),
              ("proven", is_whole_number(document["proven"])),
              ("acceptance_lines", is_whole_number(document["acceptance_lines"])),
              ("proofs", parsed_entries(document["proofs"], parsed_proof) is not None),
              ("not_checked", parsed_entries(document["not_checked"], parsed_not_checked) is not None))
    return next((key for key, sound in checks if not sound), "")


def failed(problem: str) -> ReadReport:
    return ReadReport(report=EMPTY_REPORT, problem=problem)


def read_report(reports: str) -> ReadReport:
    try:
        with open(os.path.join(reports, REPORT_FILE), encoding=TEXT_ENCODING) as report_stream:
            document = json.load(report_stream)
    except (OSError, ValueError, RecursionError) as error:
        return failed("no verify report in %s: %s" % (reports, error))
    if not isinstance(document, dict):
        return failed("no verify report in %s: %s is no JSON object" % (reports, REPORT_FILE))
    missing = [key for key in REQUIRED_KEYS if key not in document]
    if missing:
        return failed("the verify report in %s has no `%s`" % (reports, missing[0]))
    bad_key = malformed_key(document)
    if bad_key:
        return failed("the verify report in %s has a malformed `%s`" % (reports, bad_key))
    return ReadReport(report=VerifyReport(verdict=document["verdict"], proven=document["proven"],
                                          acceptance_lines=document["acceptance_lines"],
                                          proofs=parsed_entries(document["proofs"], parsed_proof),
                                          not_checked=parsed_entries(document["not_checked"], parsed_not_checked)),
                      problem="")
