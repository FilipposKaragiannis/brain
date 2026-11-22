"""Run Brain's Flow tests, the suites flow_selection.py chooses, each in a sandbox of its own.

`all --shard <number>/<count>` runs one shard of every suite, as flow_shards.py splits them.
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
from pathlib import Path
from tempfile import TemporaryDirectory

sys.dont_write_bytecode = True
sys.path.append(str(Path(__file__).resolve().parent))
from flow_clock import Clock, Duration, Ending, Instant, ending_within  # noqa: E402
from flow_process_groups import PROCESS_TABLE, LedGroup, ProcessGroupId, ProcessTable, signal_group, stop_groups  # noqa: E402
from flow_selection import Checkout, ComparisonBase, SuiteCommand, SuiteName, commands, selection  # noqa: E402
from flow_shards import WHOLE_RUN, Shard, shard_from, suites_in  # noqa: E402


_ROOT = Checkout(Path(__file__).resolve().parents[2])
_LANES_VARIABLE = "FLOW_SUITE_LANES"
_DEFAULT_LANES = 3
_TIME_LIMIT_VARIABLE = "FLOW_SUITE_TIME_LIMIT_SECONDS"
_DEFAULT_TIME_LIMIT_SECONDS = 1800
_LEAST_WHOLE_NUMBER = 1
_SIGNAL_EXIT_BASE = 128
_STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
_SHARD_OPTION = ("--shard", "<number>/<count>")
_SINCE = ("since", "<base commit>")
_USAGE = f"usage: flow_suites.py all [{' '.join(_SHARD_OPTION)}] | {' '.join(_SINCE)}"


@dataclass(frozen=True)
class LaneCount:
    count: int


@dataclass(frozen=True)
class SuiteLogs:
    folder: Path


_STOP_GRACE = Duration(10)


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
        self._suites: "set[LedGroup]" = set()
        self._lock = threading.RLock()

    @contextmanager
    def track(self, suite: LedGroup) -> Iterator[LedGroup]:
        with self._lock:
            self._suites.add(suite)
        try:
            yield suite
        finally:
            with self._lock:
                self._suites.discard(suite)

    def still_running(self) -> "frozenset[LedGroup]":
        with self._lock:
            return frozenset(self._suites)


@dataclass(frozen=True)
class _Lanes:
    directory: Path
    running: _RunningSuites
    output: threading.Lock


@dataclass(frozen=True)
class _SuiteOutcome:
    code: int
    elapsed: Duration
    ending: Ending

    def failed(self) -> bool:
        return self.code != 0 or self.ending is Ending.TIMED_OUT


def _announce(lanes: _Lanes, line: str) -> None:
    with lanes.output:
        print(line, flush=True)


def _wait_or_stop_at(suite: LedGroup, settings: Settings) -> Ending:
    ending = ending_within(lambda: suite.leader.poll() is not None, settings.time_limit, settings.clock)
    if ending is Ending.TIMED_OUT:
        stop_groups(frozenset({suite}), _STOP_GRACE, settings.clock, settings.process_table)
    return ending


def _arguments(command: SuiteCommand) -> "list[str]":
    adapter = [] if command.adapter is None else [command.adapter.text]
    return ["sh", str(command.file), *adapter]


def _run_suite(name: SuiteName, command: SuiteCommand, settings: Settings, lanes: _Lanes) -> _SuiteOutcome:
    started = settings.clock.now()
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    _announce(lanes, f"flow: {name.text} started")
    with (lanes.directory / name.text).open("wb") as output:
        with subprocess.Popen(_arguments(command), env=environment, stdout=output, stderr=subprocess.STDOUT, start_new_session=True) as process, lanes.running.track(LedGroup(process, ProcessGroupId(process.pid))) as suite:
            ending = _wait_or_stop_at(suite, settings)
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
        if outcome.ending is Ending.TIMED_OUT:
            print(f"flow: {name.text} stopped at the time limit of {limit.seconds:g}s", flush=True)
        print(f"flow: {name.text} {'FAIL' if outcome.failed() else 'pass'} ({outcome.elapsed.seconds:.1f}s)", flush=True)


def _report_stopped(number: int, workers: ThreadPoolExecutor, unfinished: "set[SuiteName]", lanes: _Lanes) -> None:
    workers.shutdown(wait=False, cancel_futures=True)
    for suite in lanes.running.still_running():
        signal_group(suite.group, signal.SIGTERM)
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


def _run(checkout: Checkout, base: "ComparisonBase | None", shard: Shard, settings: Settings) -> int:
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
    planned = _in_shard(suites, chosen.suites, shard, checkout)
    _print_plan(planned, shard)
    with TemporaryDirectory(prefix="flow-suites-") as logs:
        return report_run(run_selected(planned, SuiteLogs(Path(logs)), settings))


def _in_shard(
    suites: "Mapping[SuiteName, SuiteCommand]", chosen: "frozenset[SuiteName]", shard: Shard, checkout: Checkout
) -> "dict[SuiteName, SuiteCommand]":
    to_run = chosen & suites_in(shard, frozenset(suites), checkout)
    return {name: command for name, command in suites.items() if name in to_run}


def _print_plan(planned: "Mapping[SuiteName, SuiteCommand]", shard: Shard) -> None:
    if shard != WHOLE_RUN:
        print(f"flow: shard {shard.number}/{shard.count}", flush=True)
    print("flow: selected " + ", ".join(name.text for name in planned), flush=True)


def _shard_of(options: "list[str]") -> Shard:
    if not options:
        return WHOLE_RUN
    if len(options) != len(_SHARD_OPTION) or options[0] != _SHARD_OPTION[0]:
        sys.exit(_USAGE)
    return shard_from(options[1])


def main(arguments: "list[str]") -> int:
    if arguments[:1] == ["all"]:
        return _run(_ROOT, None, _shard_of(arguments[1:]), settings_from(os.environ, _SystemClock(), PROCESS_TABLE))
    if len(arguments) == len(_SINCE) and arguments[0] == _SINCE[0]:
        return _run(_ROOT, ComparisonBase(arguments[1]), WHOLE_RUN, settings_from(os.environ, _SystemClock(), PROCESS_TABLE))
    sys.exit(_USAGE)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
