"""Select Brain's Flow tests and run independent suites in their own sandboxes.

FLOW_SUITE_LANES sets how many suites run at once, 3 when unset. A TERM prints the output so far
of each suite still running, then ends the run.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from fnmatch import fnmatchcase
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[2]
FLOW = Path("plugins/flow")
TESTS = FLOW / "tests"
DEFAULT_LANES = 3
LANES_VARIABLE = "FLOW_SUITE_LANES"
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
STOPPED_BY_TERM = 128 + signal.SIGTERM


@dataclass(frozen=True)
class Selection:
    suites: frozenset
    notices: tuple


def suite_files(directory: Path) -> "list[Path]":
    return [
        file for file in sorted(directory.glob("*.sh"))
        if not (file.name.startswith(("_", "fake-")) or file.name == "run.sh")
    ]


def suite_entries(file: Path) -> dict:
    if file.stem == "adapter-contract":
        return {"contract-" + adapter: ("sh", file, adapter) for adapter in ADAPTERS}
    return {file.stem: ("sh", file)}


def commands(root):
    directory = root / TESTS
    suites = {"inline": ("sh", directory / "run.sh", "inline")}
    for file in suite_files(directory):
        entries = suite_entries(file)
        if entries.keys() & (suites.keys() | {"verify"}):
            raise ValueError(f"duplicate Flow suite name: {file.stem}")
        suites.update(entries)
    return suites


def changed_paths(root, base):
    def git(*arguments):
        return subprocess.check_output(("git", *arguments), cwd=root, stderr=subprocess.PIPE)

    committed = git("diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--")
    working = git("diff", "--no-renames", "--name-only", "-z", "HEAD", "--")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    return {Path(os.fsdecode(name)) for name in (committed + working + untracked).split(b"\0") if name}


def suites_by_path(suites) -> dict:
    verify_suites = {name for name in suites if name.startswith("verify-")}
    rules = {
        TESTS / "_verify_fixture.sh": verify_suites,
        TESTS / "_base_fixture.sh": set(suites) - {"inline"},
        TESTS / "adapter-contract.sh": {"contract-" + adapter for adapter in ADAPTERS},
    }
    return {**rules, **dict.fromkeys(VERIFY_INPUTS, {"verify", "base-claim", "base-readers"} | verify_suites)}


def affected(path, suites):
    rules = suites_by_path(suites)
    if path in rules and rules[path] <= suites.keys() | {"verify"}:
        return rules[path]
    if path.parent == TESTS and path.suffix == ".sh" and path.stem in suites:
        return {path.stem}
    return set(suites)


def flow_inputs(root):
    config = json.loads((root / ".standards/config.json").read_text(encoding="utf-8"))
    entry = next(check for check in config["test"] if check["name"] == "flow")
    return [pattern.replace("**/", "*").replace("**", "*") for pattern in entry["paths"]]


def matches(path: Path, patterns: Sequence[str]) -> bool:
    return any(fnmatchcase(path.as_posix(), pattern) for pattern in patterns)


def narrowed(root, paths, suites) -> Selection:
    patterns = flow_inputs(root)
    relevant = (path for path in paths if matches(path, patterns) and not matches(path, UNRELATED_TO_TESTS))
    selected = set().union(*(affected(path, suites) for path in relevant))
    if "inline" in selected:
        selected.discard("verify")
    return Selection(frozenset(selected), ())


def selection(root, base, suites) -> Selection:
    if base is None:
        return Selection(frozenset(suites), ())
    if not COMMIT_ID.fullmatch(base):
        return Selection(frozenset(suites), (BASE_UNAVAILABLE,))
    try:
        paths = changed_paths(root, base)
    except subprocess.CalledProcessError:
        return Selection(frozenset(suites), (BASE_UNAVAILABLE,))
    return narrowed(root, paths, suites)


def run_suite(command, log, clock: Callable[[], float], running: set):
    started = clock()
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    with log.open("wb") as output:
        with subprocess.Popen(command, env=environment, stdout=output, stderr=subprocess.STDOUT) as process:
            running.add(process)
            code = process.wait()
    running.discard(process)
    return code, clock() - started


def print_output(name: str, log: Path) -> None:
    prefix = f"[{name}] ".encode()
    with log.open("rb") as output:
        for line in output:
            sys.stdout.buffer.write(prefix + line.rstrip(b"\n") + b"\n")
    sys.stdout.buffer.flush()


def report_suite(name: str, outcome, log: Path) -> int:
    code, elapsed = outcome
    print_output(name, log)
    print(f"flow: {name} {'FAIL' if code else 'pass'} ({elapsed:.1f}s)", flush=True)
    return code


def report_stopped(workers: ThreadPoolExecutor, unfinished, directory: Path, running: set) -> None:
    workers.shutdown(wait=False, cancel_futures=True)
    for process in tuple(running):
        process.terminate()
    for name in sorted(name for name in unfinished if (directory / name).exists()):
        print_output(name, directory / name)
        print(f"flow: {name} stopped", flush=True)
    sys.exit(STOPPED_BY_TERM)


def run_selected(suites, directory, lanes: int, clock: Callable[[], float]) -> "list[str]":
    codes = {}
    processes = set()
    with ThreadPoolExecutor(max_workers=lanes) as workers:
        signal.signal(signal.SIGTERM, lambda number, frame: report_stopped(workers, suites.keys() - codes.keys(), directory, processes))
        running = {workers.submit(run_suite, command, directory / name, clock, processes): name for name, command in suites.items()}
        for finished in as_completed(running):
            name = running[finished]
            codes[name] = report_suite(name, finished.result(), directory / name)
    return sorted(name for name, code in codes.items() if code)


def lane_count(environment: Mapping[str, str]) -> int:
    value = environment.get(LANES_VARIABLE, str(DEFAULT_LANES))
    if not (value.isascii() and value.isdigit() and int(value) >= 1):
        sys.exit(f"flow: {LANES_VARIABLE} takes a whole number from 1, not '{value}'")
    return int(value)


def report_run(failed: "list[str]") -> int:
    print("flow: failed in " + ", ".join(failed) if failed else "flow: ok")
    return 1 if failed else 0


def run(root, base, lanes: int, clock: Callable[[], float]):
    suites = commands(root)
    chosen = selection(root, base, suites)
    for notice in chosen.notices:
        print(notice, flush=True)
    suites["verify"] = ("sh", root / TESTS / "run.sh", "verify")
    if not chosen.suites:
        print("flow: no Flow test inputs changed", flush=True)
        return 0
    missing = chosen.suites - suites.keys()
    if missing:
        sys.exit("flow: missing selected suites: " + ", ".join(sorted(missing)))
    planned = {name: command for name, command in suites.items() if name in chosen.suites}
    print("flow: selected " + ", ".join(planned), flush=True)
    with TemporaryDirectory(prefix="flow-suites-") as logs:
        return report_run(run_selected(planned, Path(logs), lanes, clock))


if __name__ == "__main__":
    if sys.argv[1:] == ["all"]:
        sys.exit(run(ROOT, None, lane_count(os.environ), time.monotonic))
    if len(sys.argv) == 3 and sys.argv[1] == "since":
        sys.exit(run(ROOT, sys.argv[2], lane_count(os.environ), time.monotonic))
    sys.exit("usage: flow_suites.py all | since <base commit>")
