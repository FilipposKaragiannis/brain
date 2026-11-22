"""Select Brain's Flow tests and run independent suites in their own sandboxes.

FLOW_SUITE_LANES sets how many suites run at once, 3 when unset. FLOW_SUITE_TIME_LIMIT_SECONDS
sets how long one suite may run, 1800 when unset. Each suite runs in a process group of its own.
The runner prints a line when a suite starts, and the suite's output with its result when it
ends. A suite still running at the limit has its process group ended, its output so far printed,
and fails. A TERM, INT or HUP prints the output so far of each suite still running, ends the
process group of each, then ends the run.
"""
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from enum import Enum
from fnmatch import fnmatchcase
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[2]
FLOW = Path("plugins/flow")
TESTS = FLOW / "tests"
DEFAULT_LANES = 3
LANES_VARIABLE = "FLOW_SUITE_LANES"
DEFAULT_TIME_LIMIT_SECONDS = 1800
TIME_LIMIT_VARIABLE = "FLOW_SUITE_TIME_LIMIT_SECONDS"
STOP_GRACE_SECONDS = 10
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
SIGNAL_EXIT_BASE = 128
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


@dataclass(frozen=True)
class Selection:
    suites: frozenset
    notices: tuple


@dataclass(frozen=True)
class Settings:
    lanes: int
    limit_seconds: int
    clock: Callable[[], float]


@dataclass(frozen=True)
class Lanes:
    directory: Path
    running: set
    output: threading.Lock


class Ending(Enum):
    EXITED = "exited"
    TIMED_OUT = "timed out"


@dataclass(frozen=True)
class SuiteOutcome:
    code: int
    elapsed: float
    ending: Ending

    def failed(self) -> bool:
        return self.code != 0 or self.ending is Ending.TIMED_OUT


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
    suites = {}
    for file in suite_files(directory):
        entries = suite_entries(file)
        if entries.keys() & suites.keys():
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
        TESTS / "_base_fixture.sh": set(suites),
        TESTS / "adapter-contract.sh": {"contract-" + adapter for adapter in ADAPTERS},
    }
    return {**rules, **dict.fromkeys(VERIFY_INPUTS, {"verify-report", "base-claim", "base-readers"} | verify_suites)}


def affected(path, suites):
    rules = suites_by_path(suites)
    if path in rules and rules[path] <= suites.keys():
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


def announce(lanes: Lanes, line: str) -> None:
    with lanes.output:
        print(line, flush=True)


def stop_at_limit(process: subprocess.Popen) -> None:
    end_process_group(process, signal.SIGTERM)
    try:
        process.wait(timeout=STOP_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        end_process_group(process, signal.SIGKILL)


def wait_within(process: subprocess.Popen, limit_seconds: int) -> Ending:
    try:
        process.wait(timeout=limit_seconds)
    except subprocess.TimeoutExpired:
        stop_at_limit(process)
        return Ending.TIMED_OUT
    return Ending.EXITED


def run_suite(name: str, command: tuple, settings: Settings, lanes: Lanes) -> SuiteOutcome:
    started = settings.clock()
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    announce(lanes, f"flow: {name} started")
    with (lanes.directory / name).open("wb") as output:
        with subprocess.Popen(command, env=environment, stdout=output, stderr=subprocess.STDOUT, start_new_session=True) as process:
            lanes.running.add(process)
            ending = wait_within(process, settings.limit_seconds)
            code = process.wait()
    lanes.running.discard(process)
    return SuiteOutcome(code, settings.clock() - started, ending)


def print_output(name: str, log: Path) -> None:
    prefix = f"[{name}] ".encode()
    with log.open("rb") as output:
        for line in output:
            sys.stdout.buffer.write(prefix + line.rstrip(b"\n") + b"\n")
    sys.stdout.buffer.flush()


def report_suite(name: str, outcome: SuiteOutcome, lanes: Lanes, limit_seconds: int) -> bool:
    with lanes.output:
        print_output(name, lanes.directory / name)
        if outcome.ending is Ending.TIMED_OUT:
            print(f"flow: {name} stopped at the time limit of {limit_seconds}s", flush=True)
        print(f"flow: {name} {'FAIL' if outcome.failed() else 'pass'} ({outcome.elapsed:.1f}s)", flush=True)
    return outcome.failed()


def end_process_group(process: subprocess.Popen, number: signal.Signals) -> None:
    try:
        os.killpg(process.pid, number)
    except ProcessLookupError:
        pass


def report_stopped(number: int, workers: ThreadPoolExecutor, unfinished, directory: Path, running: set) -> None:
    workers.shutdown(wait=False, cancel_futures=True)
    for process in tuple(running):
        end_process_group(process, signal.SIGTERM)
    for name in sorted(name for name in unfinished if (directory / name).exists()):
        print_output(name, directory / name)
        print(f"flow: {name} stopped", flush=True)
    sys.exit(SIGNAL_EXIT_BASE + number)


def run_selected(suites: "dict[str, tuple]", directory: Path, settings: Settings) -> "list[str]":
    failures = {}
    lanes = Lanes(directory, set(), threading.Lock())
    with ThreadPoolExecutor(max_workers=settings.lanes) as workers:
        for stop_signal in STOP_SIGNALS:
            signal.signal(stop_signal, lambda number, frame: report_stopped(number, workers, suites.keys() - failures.keys(), directory, lanes.running))
        running = {workers.submit(run_suite, name, command, settings, lanes): name for name, command in suites.items()}
        for finished in as_completed(running):
            name = running[finished]
            failures[name] = report_suite(name, finished.result(), lanes, settings.limit_seconds)
    return sorted(name for name, failed in failures.items() if failed)


def whole_number_from_one(environment: Mapping[str, str], variable: str, default: int, meaning: str) -> int:
    value = environment.get(variable, str(default))
    if not (value.isascii() and value.isdigit() and int(value) >= 1):
        sys.exit(f"flow: {variable} takes {meaning} from 1, not '{value}'")
    return int(value)


def settings_from(environment: Mapping[str, str], clock: Callable[[], float]) -> Settings:
    lanes = whole_number_from_one(environment, LANES_VARIABLE, DEFAULT_LANES, "a whole number")
    limit_seconds = whole_number_from_one(environment, TIME_LIMIT_VARIABLE, DEFAULT_TIME_LIMIT_SECONDS, "a whole number of seconds")
    return Settings(lanes, limit_seconds, clock)


def report_run(failed: "list[str]") -> int:
    print("flow: failed in " + ", ".join(failed) if failed else "flow: ok")
    return 1 if failed else 0


def run(root: Path, base: "str | None", settings: Settings) -> int:
    suites = commands(root)
    chosen = selection(root, base, suites)
    for notice in chosen.notices:
        print(notice, flush=True)
    if not chosen.suites:
        print("flow: no Flow test inputs changed", flush=True)
        return 0
    missing = chosen.suites - suites.keys()
    if missing:
        sys.exit("flow: missing selected suites: " + ", ".join(sorted(missing)))
    planned = {name: command for name, command in suites.items() if name in chosen.suites}
    print("flow: selected " + ", ".join(planned), flush=True)
    with TemporaryDirectory(prefix="flow-suites-") as logs:
        return report_run(run_selected(planned, Path(logs), settings))


if __name__ == "__main__":
    if sys.argv[1:] == ["all"]:
        sys.exit(run(ROOT, None, settings_from(os.environ, time.monotonic)))
    if len(sys.argv) == 3 and sys.argv[1] == "since":
        sys.exit(run(ROOT, sys.argv[2], settings_from(os.environ, time.monotonic)))
    sys.exit("usage: flow_suites.py all | since <base commit>")
