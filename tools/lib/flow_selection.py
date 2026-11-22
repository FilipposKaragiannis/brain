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
class Selection:
    suites: "frozenset[str]"
    notices: "tuple[str, ...]"


def suite_files(directory: Path) -> "list[Path]":
    return [
        file for file in sorted(directory.glob("*.sh"))
        if not (file.name.startswith(("_", "fake-")) or file.name == "run.sh")
    ]


def suite_entries(file: Path) -> "dict[str, tuple]":
    if file.stem == "adapter-contract":
        return {"contract-" + adapter: ("sh", file, adapter) for adapter in ADAPTERS}
    return {file.stem: ("sh", file)}


def commands(root: Path) -> "dict[str, tuple]":
    directory = root / TESTS
    suites = {}
    for file in suite_files(directory):
        entries = suite_entries(file)
        if entries.keys() & suites.keys():
            raise ValueError(f"duplicate Flow suite name: {file.stem}")
        suites.update(entries)
    return suites


def changed_paths(root: Path, base: str) -> "set[Path]":
    def git(*arguments: str) -> bytes:
        return subprocess.check_output(("git", *arguments), cwd=root, stderr=subprocess.PIPE)

    committed = git("diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--")
    working = git("diff", "--no-renames", "--name-only", "-z", "HEAD", "--")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    return {Path(os.fsdecode(name)) for name in (committed + working + untracked).split(b"\0") if name}


def suites_by_path(suites: "Mapping[str, tuple]") -> "dict[Path, frozenset[str]]":
    verify_suites = frozenset(name for name in suites if name.startswith("verify-"))
    rules = {
        TESTS / "_verify_fixture.sh": verify_suites,
        TESTS / "_base_fixture.sh": frozenset(suites),
        TESTS / "adapter-contract.sh": frozenset("contract-" + adapter for adapter in ADAPTERS),
    }
    return {**rules, **dict.fromkeys(VERIFY_INPUTS, frozenset({"verify-report", "base-claim", "base-readers"}) | verify_suites)}


def affected(path: Path, suites: "Mapping[str, tuple]") -> "frozenset[str]":
    rules = suites_by_path(suites)
    if path in rules and rules[path] <= suites.keys():
        return rules[path]
    if path.parent == TESTS and path.suffix == ".sh" and path.stem in suites:
        return frozenset({path.stem})
    return frozenset(suites)


def flow_inputs(root: Path) -> "list[str]":
    config = json.loads((root / ".standards/config.json").read_text(encoding="utf-8"))
    entry = next(check for check in config["test"] if check["name"] == "flow")
    return [pattern.replace("**/", "*").replace("**", "*") for pattern in entry["paths"]]


def matches(path: Path, patterns: Sequence[str]) -> bool:
    return any(fnmatchcase(path.as_posix(), pattern) for pattern in patterns)


def narrowed(root: Path, paths: "set[Path]", suites: "Mapping[str, tuple]") -> Selection:
    patterns = flow_inputs(root)
    relevant = (path for path in paths if matches(path, patterns) and not matches(path, UNRELATED_TO_TESTS))
    return Selection(frozenset().union(*(affected(path, suites) for path in relevant)), ())


def selection(root: Path, base: "str | None", suites: "Mapping[str, tuple]") -> Selection:
    if base is None:
        return Selection(frozenset(suites), ())
    if not COMMIT_ID.fullmatch(base):
        return Selection(frozenset(suites), (BASE_UNAVAILABLE,))
    try:
        paths = changed_paths(root, base)
    except subprocess.CalledProcessError:
        return Selection(frozenset(suites), (BASE_UNAVAILABLE,))
    return narrowed(root, paths, suites)
