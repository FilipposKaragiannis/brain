"""Name Brain's Flow suites and choose the ones a change since a base commit affects."""
import json
import os
import re
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import Path


FLOW = Path("plugins/flow")
TESTS = FLOW / "tests"
ADAPTERS = ("github", "local", "jira")
VERIFY_INPUTS = {
    FLOW / "scripts" / name for name in ("verify.sh", "_verify_report.py", "_checks.py")
} | {FLOW / "lib/checks.sh"}
UNRELATED_TO_TESTS = (
    "plugins/flow/CHANGELOG.md",
    "plugins/flow/changelog.d/*",
    "plugins/flow/README.md",
    "plugins/flow/*/README.md",
)
COMMIT_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
BASE_UNAVAILABLE = "flow: no comparison base available, running every suite"


@dataclass(frozen=True)
class Checkout:
    folder: Path


@dataclass(frozen=True)
class ComparisonBase:
    text: str


@dataclass(frozen=True, order=True)
class SuiteName:
    text: str


@dataclass(frozen=True)
class Selection:
    suites: "frozenset[SuiteName]"
    notices: "tuple[str, ...]"


def _suite_files(directory: Path) -> "list[Path]":
    return [
        file for file in sorted(directory.glob("*.sh"))
        if not (file.name.startswith(("_", "fake-")) or file.name == "run.sh")
    ]


def _suite_entries(file: Path) -> "dict[SuiteName, tuple]":
    if file.stem == "adapter-contract":
        return {SuiteName("contract-" + adapter): ("sh", file, adapter) for adapter in ADAPTERS}
    return {SuiteName(file.stem): ("sh", file)}


def commands(checkout: Checkout) -> "dict[SuiteName, tuple]":
    directory = checkout.folder / TESTS
    suites = {}
    for file in _suite_files(directory):
        entries = _suite_entries(file)
        if entries.keys() & suites.keys():
            raise ValueError(f"duplicate Flow suite name: {file.stem}")
        suites.update(entries)
    return suites


def _changed_paths(checkout: Checkout, base: ComparisonBase) -> "set[Path]":
    def git(*arguments: str) -> bytes:
        return subprocess.check_output(("git", *arguments), cwd=checkout.folder, stderr=subprocess.PIPE)

    committed = git("diff", "--no-renames", "--name-only", "-z", base.text, "HEAD", "--")
    working = git("diff", "--no-renames", "--name-only", "-z", "HEAD", "--")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    return {Path(os.fsdecode(name)) for name in (committed + working + untracked).split(b"\0") if name}


def _suites_by_path(suites: "Mapping[SuiteName, tuple]") -> "dict[Path, frozenset[SuiteName]]":
    verify_suites = frozenset(name for name in suites if name.text.startswith("verify-"))
    rules = {
        TESTS / "_verify_fixture.sh": verify_suites,
        TESTS / "_base_fixture.sh": frozenset(suites),
        TESTS / "adapter-contract.sh": frozenset(SuiteName("contract-" + adapter) for adapter in ADAPTERS),
    }
    readers_of_verify = frozenset(SuiteName(name) for name in ("verify-report", "base-claim", "base-readers")) | verify_suites
    return {**rules, **dict.fromkeys(VERIFY_INPUTS, readers_of_verify)}


def _affected(path: Path, suites: "Mapping[SuiteName, tuple]") -> "frozenset[SuiteName]":
    rules = _suites_by_path(suites)
    if path in rules and rules[path] <= suites.keys():
        return rules[path]
    if path.parent == TESTS and path.suffix == ".sh" and SuiteName(path.stem) in suites:
        return frozenset({SuiteName(path.stem)})
    return frozenset(suites)


def _flow_inputs(checkout: Checkout) -> "list[str]":
    config = json.loads((checkout.folder / ".standards/config.json").read_text(encoding="utf-8"))
    entry = next(check for check in config["test"] if check["name"] == "flow")
    return [pattern.replace("**/", "*").replace("**", "*") for pattern in entry["paths"]]


def _matches(path: Path, patterns: Sequence[str]) -> bool:
    return any(fnmatchcase(path.as_posix(), pattern) for pattern in patterns)


def _narrowed(checkout: Checkout, paths: "set[Path]", suites: "Mapping[SuiteName, tuple]") -> Selection:
    patterns = _flow_inputs(checkout)
    relevant = (path for path in paths if _matches(path, patterns) and not _matches(path, UNRELATED_TO_TESTS))
    return Selection(frozenset().union(*(_affected(path, suites) for path in relevant)), ())


def selection(checkout: Checkout, base: "ComparisonBase | None", suites: "Mapping[SuiteName, tuple]") -> Selection:
    if base is None:
        return Selection(frozenset(suites), ())
    if not COMMIT_ID.fullmatch(base.text):
        return Selection(frozenset(suites), (BASE_UNAVAILABLE,))
    try:
        paths = _changed_paths(checkout, base)
    except subprocess.CalledProcessError:
        return Selection(frozenset(suites), (BASE_UNAVAILABLE,))
    return _narrowed(checkout, paths, suites)
