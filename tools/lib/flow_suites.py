"""Run Brain's Flow tests, the suites flow_selection.py chooses, each in a sandbox of its own.

FLOW_SUITE_LANES sets how many suites run at once, 3 when unset. FLOW_SUITE_TIME_LIMIT_SECONDS
sets how long one suite may run, 1800 when unset. Each suite runs in a process group of its own.
The runner prints a line when a suite starts, and the suite's output with its result when it
ends. A suite still running at the limit has its process group ended, what is left of the group
killed once a grace time passes, its output so far printed, and fails. A TERM, INT or HUP prints
the output so far of each suite still running, ends the process group of each, then ends the run.
"""
import os
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator, Mapping
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Protocol

sys.dont_write_bytecode = True
sys.path.append(str(Path(__file__).resolve().parent))
from flow_selection import commands, selection  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
LANES_VARIABLE = "FLOW_SUITE_LANES"
DEFAULT_LANES = 3
TIME_LIMIT_VARIABLE = "FLOW_SUITE_TIME_LIMIT_SECONDS"
DEFAULT_TIME_LIMIT_SECONDS = 1800
LEAST_WHOLE_NUMBER = 1
SIGNAL_EXIT_BASE = 128
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
PRESENCE_PROBE_SIGNAL = 0
ZOMBIE_STATE = "Z"
PROCESS_TABLE = Path("/proc")
STATE_FIELD = 0
PROCESS_GROUP_FIELD = 2
LISTING_GROUP_COLUMN = 0
LISTING_STATE_COLUMN = 1
LISTING_COLUMNS = 2


@dataclass(frozen=True)
class Duration:
    seconds: float


@dataclass(frozen=True)
class LaneCount:
    count: int


STOP_GRACE = Duration(10)
POLL_INTERVAL = Duration(0.1)
PROCESS_LISTING_LIMIT = Duration(10)


class Clock(Protocol):
    def now(self) -> float: ...

    def sleep(self, duration: Duration) -> None: ...


class SystemClock:
    def now(self) -> float:
        return time.monotonic()

    def sleep(self, duration: Duration) -> None:
        time.sleep(duration.seconds)


@dataclass(frozen=True)
class Settings:
    lanes: LaneCount
    time_limit: Duration
    clock: Clock


class RunningSuites:
    def __init__(self) -> None:
        self._processes: "set[subprocess.Popen]" = set()
        self._lock = threading.RLock()

    @contextmanager
    def track(self, process: subprocess.Popen) -> Iterator[None]:
        with self._lock:
            self._processes.add(process)
        try:
            yield
        finally:
            with self._lock:
                self._processes.discard(process)

    def still_running(self) -> "tuple[subprocess.Popen, ...]":
        with self._lock:
            return tuple(self._processes)


@dataclass(frozen=True)
class Lanes:
    directory: Path
    running: RunningSuites
    output: threading.Lock


class Ending(Enum):
    EXITED = "exited"
    TIMED_OUT = "timed out"


@dataclass(frozen=True)
class SuiteOutcome:
    code: int
    elapsed: Duration
    ending: Ending

    def failed(self) -> bool:
        return self.code != 0 or self.ending is Ending.TIMED_OUT


def announce(lanes: Lanes, line: str) -> None:
    with lanes.output:
        print(line, flush=True)


def signal_group(process: subprocess.Popen, number: signal.Signals) -> bool:
    try:
        os.killpg(process.pid, number)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def names_group(field: str, group: int) -> bool:
    return field.isascii() and field.isdigit() and int(field) == group


def fields_after_name(status: Path) -> "list[str]":
    try:
        line = status.read_bytes().decode(errors="replace")
    except OSError:
        return []
    return line.rpartition(")")[2].split() if ")" in line else []


def states_in_process_table(group: int, table: Path) -> "list[str]":
    rows = (fields_after_name(status) for status in table.glob("[0-9]*/stat"))
    return [fields[STATE_FIELD] for fields in rows if len(fields) > PROCESS_GROUP_FIELD and names_group(fields[PROCESS_GROUP_FIELD], group)]


def process_listing_lines() -> "list[str]":
    try:
        listing = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, timeout=PROCESS_LISTING_LIMIT.seconds, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return listing.stdout.decode(errors="replace").splitlines() if listing.returncode == 0 else []


def states_in_process_listing(group: int) -> "list[str]":
    rows = (line.split() for line in process_listing_lines())
    return [row[LISTING_STATE_COLUMN] for row in rows if len(row) == LISTING_COLUMNS and names_group(row[LISTING_GROUP_COLUMN], group)]


def member_states(group: int) -> "list[str]":
    return states_in_process_table(group, PROCESS_TABLE) if PROCESS_TABLE.is_dir() else states_in_process_listing(group)


def group_has_members(process: subprocess.Popen) -> bool:
    try:
        os.killpg(process.pid, PRESENCE_PROBE_SIGNAL)
    except (ProcessLookupError, PermissionError):
        return False
    return any(not state.startswith(ZOMBIE_STATE) for state in member_states(process.pid))


def group_ended(process: subprocess.Popen) -> bool:
    return process.poll() is not None and not group_has_members(process)


def ending_within(ended: Callable[[], bool], limit: Duration, clock: Clock) -> Ending:
    deadline = clock.now() + limit.seconds
    while not ended():
        if clock.now() >= deadline:
            return Ending.TIMED_OUT
        clock.sleep(POLL_INTERVAL)
    return Ending.EXITED


def stop_group(process: subprocess.Popen, clock: Clock) -> None:
    signal_group(process, signal.SIGTERM)
    if ending_within(lambda: group_ended(process), STOP_GRACE, clock) is Ending.TIMED_OUT:
        signal_group(process, signal.SIGKILL)


def wait_or_stop_at(process: subprocess.Popen, limit: Duration, clock: Clock) -> Ending:
    ending = ending_within(lambda: process.poll() is not None, limit, clock)
    if ending is Ending.TIMED_OUT:
        stop_group(process, clock)
    return ending


def run_suite(name: str, command: tuple, settings: Settings, lanes: Lanes) -> SuiteOutcome:
    started = settings.clock.now()
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    announce(lanes, f"flow: {name} started")
    with (lanes.directory / name).open("wb") as output:
        with subprocess.Popen(command, env=environment, stdout=output, stderr=subprocess.STDOUT, start_new_session=True) as process, lanes.running.track(process):
            ending = wait_or_stop_at(process, settings.time_limit, settings.clock)
            code = process.wait()
    return SuiteOutcome(code, Duration(settings.clock.now() - started), ending)


def print_output(name: str, log: Path) -> None:
    prefix = f"[{name}] ".encode()
    with log.open("rb") as output:
        for line in output:
            sys.stdout.buffer.write(prefix + line.rstrip(b"\n") + b"\n")
    sys.stdout.buffer.flush()


def report_suite(name: str, outcome: SuiteOutcome, lanes: Lanes, limit: Duration) -> None:
    with lanes.output:
        print_output(name, lanes.directory / name)
        if outcome.ending is Ending.TIMED_OUT:
            print(f"flow: {name} stopped at the time limit of {limit.seconds:g}s", flush=True)
        print(f"flow: {name} {'FAIL' if outcome.failed() else 'pass'} ({outcome.elapsed.seconds:.1f}s)", flush=True)


def report_stopped(number: int, workers: ThreadPoolExecutor, unfinished: "set[str]", lanes: Lanes) -> None:
    workers.shutdown(wait=False, cancel_futures=True)
    for process in lanes.running.still_running():
        signal_group(process, signal.SIGTERM)
    for name in sorted(name for name in unfinished if (lanes.directory / name).exists()):
        print_output(name, lanes.directory / name)
        print(f"flow: {name} stopped", flush=True)
    sys.exit(SIGNAL_EXIT_BASE + number)


def stop_on_signals(workers: ThreadPoolExecutor, unfinished: "Callable[[], set[str]]", lanes: Lanes) -> None:
    for stop_signal in STOP_SIGNALS:
        signal.signal(stop_signal, lambda number, frame: report_stopped(number, workers, unfinished(), lanes))


def run_selected(suites: "dict[str, tuple]", directory: Path, settings: Settings) -> "list[str]":
    outcomes = {}
    lanes = Lanes(directory, RunningSuites(), threading.Lock())
    with ThreadPoolExecutor(max_workers=settings.lanes.count) as workers:
        stop_on_signals(workers, lambda: suites.keys() - outcomes.keys(), lanes)
        running = {workers.submit(run_suite, name, command, settings, lanes): name for name, command in suites.items()}
        for finished in as_completed(running):
            name = running[finished]
            outcomes[name] = finished.result()
            report_suite(name, outcomes[name], lanes, settings.time_limit)
    return sorted(name for name, outcome in outcomes.items() if outcome.failed())


def _whole_number_from_one(environment: Mapping[str, str], variable: str, default: int, meaning: str) -> int:
    value = environment.get(variable, str(default))
    if not (value.isascii() and value.isdigit() and int(value) >= LEAST_WHOLE_NUMBER):
        sys.exit(f"flow: {variable} takes {meaning} from {LEAST_WHOLE_NUMBER}, not '{value}'")
    return int(value)


def lane_count_from(environment: Mapping[str, str]) -> LaneCount:
    return LaneCount(_whole_number_from_one(environment, LANES_VARIABLE, DEFAULT_LANES, "a whole number"))


def time_limit_from(environment: Mapping[str, str]) -> Duration:
    return Duration(_whole_number_from_one(environment, TIME_LIMIT_VARIABLE, DEFAULT_TIME_LIMIT_SECONDS, "a whole number of seconds"))


def settings_from(environment: Mapping[str, str], clock: Clock) -> Settings:
    return Settings(lane_count_from(environment), time_limit_from(environment), clock)


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


def main(arguments: "list[str]") -> int:
    if arguments == ["all"]:
        return run(ROOT, None, settings_from(os.environ, SystemClock()))
    if len(arguments) == 2 and arguments[0] == "since":
        return run(ROOT, arguments[1], settings_from(os.environ, SystemClock()))
    sys.exit("usage: flow_suites.py all | since <base commit>")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
