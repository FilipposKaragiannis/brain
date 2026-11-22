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
from flow_process_groups import PROCESS_TABLE, ProcessGroupId, ProcessTable, group_ended, signal_group  # noqa: E402
from flow_selection import Checkout, ComparisonBase, SuiteCommand, SuiteName, commands, selection  # noqa: E402


_ROOT = Checkout(Path(__file__).resolve().parents[2])
_LANES_VARIABLE = "FLOW_SUITE_LANES"
_DEFAULT_LANES = 3
_TIME_LIMIT_VARIABLE = "FLOW_SUITE_TIME_LIMIT_SECONDS"
_DEFAULT_TIME_LIMIT_SECONDS = 1800
_LEAST_WHOLE_NUMBER = 1
_SIGNAL_EXIT_BASE = 128
_STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


@dataclass(frozen=True)
class Duration:
    seconds: float


@dataclass(frozen=True)
class Instant:
    seconds: float


@dataclass(frozen=True)
class LaneCount:
    count: int


@dataclass(frozen=True)
class SuiteLogs:
    folder: Path


_STOP_GRACE = Duration(10)
_POLL_INTERVAL = Duration(0.1)


class Clock(Protocol):
    def now(self) -> Instant: ...

    def sleep(self, duration: Duration) -> None: ...


class _SystemClock:
    def now(self) -> Instant:
        return Instant(time.monotonic())

    def sleep(self, duration: Duration) -> None:
        time.sleep(duration.seconds)


@dataclass(frozen=True)
class Settings:
    lanes: LaneCount
    time_limit: Duration
    clock: Clock
    process_table: ProcessTable


class _RunningSuites:
    def __init__(self) -> None:
        self._groups: "set[ProcessGroupId]" = set()
        self._lock = threading.RLock()

    @contextmanager
    def track(self, group: ProcessGroupId) -> Iterator[ProcessGroupId]:
        with self._lock:
            self._groups.add(group)
        try:
            yield group
        finally:
            with self._lock:
                self._groups.discard(group)

    def still_running(self) -> "tuple[ProcessGroupId, ...]":
        with self._lock:
            return tuple(self._groups)


@dataclass(frozen=True)
class _Lanes:
    directory: Path
    running: _RunningSuites
    output: threading.Lock


class _Ending(Enum):
    EXITED = "exited"
    TIMED_OUT = "timed out"


@dataclass(frozen=True)
class _SuiteOutcome:
    code: int
    elapsed: Duration
    ending: _Ending

    def failed(self) -> bool:
        return self.code != 0 or self.ending is _Ending.TIMED_OUT


def _announce(lanes: _Lanes, line: str) -> None:
    with lanes.output:
        print(line, flush=True)


def _ending_within(ended: Callable[[], bool], limit: Duration, clock: Clock) -> _Ending:
    deadline = clock.now().seconds + limit.seconds
    while not ended():
        if clock.now().seconds >= deadline:
            return _Ending.TIMED_OUT
        clock.sleep(_POLL_INTERVAL)
    return _Ending.EXITED


def _stop_group(leader: subprocess.Popen, group: ProcessGroupId, settings: Settings) -> None:
    signal_group(group, signal.SIGTERM)
    if _ending_within(lambda: group_ended(leader, group, settings.process_table), _STOP_GRACE, settings.clock) is _Ending.TIMED_OUT:
        signal_group(group, signal.SIGKILL)


def _wait_or_stop_at(leader: subprocess.Popen, group: ProcessGroupId, settings: Settings) -> _Ending:
    ending = _ending_within(lambda: leader.poll() is not None, settings.time_limit, settings.clock)
    if ending is _Ending.TIMED_OUT:
        _stop_group(leader, group, settings)
    return ending


def _arguments(command: SuiteCommand) -> "list[str]":
    adapter = [] if command.adapter is None else [command.adapter.text]
    return ["sh", str(command.file), *adapter]


def _run_suite(name: SuiteName, command: SuiteCommand, settings: Settings, lanes: _Lanes) -> _SuiteOutcome:
    started = settings.clock.now()
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    _announce(lanes, f"flow: {name.text} started")
    with (lanes.directory / name.text).open("wb") as output:
        with subprocess.Popen(_arguments(command), env=environment, stdout=output, stderr=subprocess.STDOUT, start_new_session=True) as process, lanes.running.track(ProcessGroupId(process.pid)) as group:
            ending = _wait_or_stop_at(process, group, settings)
            code = process.wait()
    return _SuiteOutcome(code, Duration(settings.clock.now().seconds - started.seconds), ending)


def _print_output(name: SuiteName, log: Path) -> None:
    prefix = f"[{name.text}] ".encode()
    with log.open("rb") as output:
        for line in output:
            sys.stdout.buffer.write(prefix + line.rstrip(b"\n") + b"\n")
    sys.stdout.buffer.flush()


def _report_suite(name: SuiteName, outcome: _SuiteOutcome, lanes: _Lanes, limit: Duration) -> None:
    with lanes.output:
        _print_output(name, lanes.directory / name.text)
        if outcome.ending is _Ending.TIMED_OUT:
            print(f"flow: {name.text} stopped at the time limit of {limit.seconds:g}s", flush=True)
        print(f"flow: {name.text} {'FAIL' if outcome.failed() else 'pass'} ({outcome.elapsed.seconds:.1f}s)", flush=True)


def _report_stopped(number: int, workers: ThreadPoolExecutor, unfinished: "set[SuiteName]", lanes: _Lanes) -> None:
    workers.shutdown(wait=False, cancel_futures=True)
    for group in lanes.running.still_running():
        signal_group(group, signal.SIGTERM)
    for name in sorted(name for name in unfinished if (lanes.directory / name.text).exists()):
        _print_output(name, lanes.directory / name.text)
        print(f"flow: {name.text} stopped", flush=True)
    sys.exit(_SIGNAL_EXIT_BASE + number)


def _stop_on_signals(workers: ThreadPoolExecutor, unfinished: "Callable[[], set[SuiteName]]", lanes: _Lanes) -> None:
    for stop_signal in _STOP_SIGNALS:
        signal.signal(stop_signal, lambda number, frame: _report_stopped(number, workers, unfinished(), lanes))


def run_selected(suites: "Mapping[SuiteName, SuiteCommand]", logs: SuiteLogs, settings: Settings) -> "frozenset[SuiteName]":
    outcomes = {}
    lanes = _Lanes(logs.folder, _RunningSuites(), threading.Lock())
    with ThreadPoolExecutor(max_workers=settings.lanes.count) as workers:
        _stop_on_signals(workers, lambda: suites.keys() - outcomes.keys(), lanes)
        running = {workers.submit(_run_suite, name, command, settings, lanes): name for name, command in suites.items()}
        for finished in as_completed(running):
            name = running[finished]
            outcomes[name] = finished.result()
            _report_suite(name, outcomes[name], lanes, settings.time_limit)
    return frozenset(name for name, outcome in outcomes.items() if outcome.failed())


def _whole_number_from_one(environment: Mapping[str, str], variable: str, default: int, meaning: str) -> int:
    value = environment.get(variable, str(default))
    if not (value.isascii() and value.isdigit() and int(value) >= _LEAST_WHOLE_NUMBER):
        sys.exit(f"flow: {variable} takes {meaning} from {_LEAST_WHOLE_NUMBER}, not '{value}'")
    return int(value)


def _lane_count_from(environment: Mapping[str, str]) -> LaneCount:
    return LaneCount(_whole_number_from_one(environment, _LANES_VARIABLE, _DEFAULT_LANES, "a whole number"))


def _time_limit_from(environment: Mapping[str, str]) -> Duration:
    return Duration(_whole_number_from_one(environment, _TIME_LIMIT_VARIABLE, _DEFAULT_TIME_LIMIT_SECONDS, "a whole number of seconds"))


def settings_from(environment: Mapping[str, str], clock: Clock, process_table: ProcessTable) -> Settings:
    return Settings(_lane_count_from(environment), _time_limit_from(environment), clock, process_table)


def report_run(failed: "frozenset[SuiteName]") -> int:
    print("flow: failed in " + ", ".join(name.text for name in sorted(failed)) if failed else "flow: ok")
    return 1 if failed else 0


def _run(checkout: Checkout, base: "ComparisonBase | None", settings: Settings) -> int:
    suites = commands(checkout)
    chosen = selection(checkout, base, suites)
    if chosen.notice is not None:
        print(chosen.notice.text, flush=True)
    if not chosen.suites:
        print("flow: no Flow test inputs changed", flush=True)
        return 0
    missing = chosen.suites - suites.keys()
    if missing:
        sys.exit("flow: missing selected suites: " + ", ".join(name.text for name in sorted(missing)))
    planned = {name: command for name, command in suites.items() if name in chosen.suites}
    print("flow: selected " + ", ".join(name.text for name in planned), flush=True)
    with TemporaryDirectory(prefix="flow-suites-") as logs:
        return report_run(run_selected(planned, SuiteLogs(Path(logs)), settings))


def main(arguments: "list[str]") -> int:
    if arguments == ["all"]:
        return _run(_ROOT, None, settings_from(os.environ, _SystemClock(), PROCESS_TABLE))
    if len(arguments) == 2 and arguments[0] == "since":
        return _run(_ROOT, ComparisonBase(arguments[1]), settings_from(os.environ, _SystemClock(), PROCESS_TABLE))
    sys.exit("usage: flow_suites.py all | since <base commit>")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
