"""Runners that flow_runner_stop.py starts in place of flow_suites.py. Each runs stub suites through
flow_suites.run_selected with one thing changed, so that a stop lands at a chosen moment or meets a
chosen obstacle: late-start stops the run as a lane starts its second suite, early-stop as the first
suite is handed to a lane, finishing-suite while the main thread collects one finished suite and a
lane holds another that has just finished, and listing-hang runs with no process table so that a
look at a group goes through the process listing. Takes the runner's name, then its stub suite
files, its log folder and what that runner needs besides."""
import signal
import sys
import threading
import time
from collections.abc import Callable
from concurrent.futures import Future, _base
from pathlib import Path
from typing import TextIO

sys.dont_write_bytecode = True
sys.path.append(str(Path(__file__).resolve().parents[1] / "lib"))
import flow_clock  # noqa: E402
import flow_process_groups  # noqa: E402
import flow_selection  # noqa: E402
import flow_suites  # noqa: E402

AWAIT_LIMIT_SECONDS = 30
LATE_START_LINE = "flow: late started"
STOP_SIGNAL = signal.SIGTERM
LANES_VARIABLE = "FLOW_SUITE_LANES"
STOP_GRACE_VARIABLE = "FLOW_SUITE_STOP_GRACE_SECONDS"
ONE_LANE = "1"
TWO_LANES = "2"


def run(scripts: "dict[str, str]", logs: str, settings: flow_suites.Settings) -> int:
    suites = {flow_selection.SuiteName(name): flow_selection.SuiteCommand(Path(script), None) for name, script in scripts.items()}
    return flow_suites.report_run(flow_suites.run_selected(suites, flow_suites.SuiteLogs(Path(logs)), settings))


def in_main_thread() -> bool:
    return threading.current_thread() is threading.main_thread()


class ClockThatTellsWhenTheStopIsUnderWay:
    def __init__(self) -> None:
        self.stop_under_way = threading.Event()

    def now(self) -> flow_clock.Instant:
        if in_main_thread():
            self.stop_under_way.set()
        return flow_clock.Instant(time.monotonic())

    def sleep(self, duration: flow_clock.Duration) -> None:
        time.sleep(duration.seconds)


class OutputThatStopsTheRunAsTheLateSuiteStarts:
    def __init__(self, output: TextIO, stop_under_way: threading.Event) -> None:
        self.output = output
        self.buffer = output.buffer
        self.stop_under_way = stop_under_way

    def write(self, text: str) -> int:
        self.output.write(text)
        if text == LATE_START_LINE:
            self.output.flush()
            signal.pthread_kill(threading.main_thread().ident, STOP_SIGNAL)
            self.stop_under_way.wait(AWAIT_LIMIT_SECONDS)
        return len(text)

    def flush(self) -> None:
        self.output.flush()


def late_start(arguments: "list[str]") -> int:
    first_script, late_script, logs, grace = arguments
    clock = ClockThatTellsWhenTheStopIsUnderWay()
    sys.stdout = OutputThatStopsTheRunAsTheLateSuiteStarts(sys.stdout, clock.stop_under_way)
    settings = flow_suites.settings_from({LANES_VARIABLE: ONE_LANE, STOP_GRACE_VARIABLE: grace}, clock, flow_process_groups.PROCESS_TABLE)
    return run({"first": first_script, "late": late_script}, logs, settings)


def lane_start_that_stops_the_run(start: "Callable[[threading.Thread], None]") -> "Callable[[threading.Thread], None]":
    def start_a_lane_then_stop_the_run(lane: threading.Thread) -> None:
        start(lane)
        signal.raise_signal(STOP_SIGNAL)

    return start_a_lane_then_stop_the_run


def early_stop(arguments: "list[str]") -> int:
    early_script, logs = arguments
    threading.Thread.start = lane_start_that_stops_the_run(threading.Thread.start)
    settings = flow_suites.settings_from({}, flow_clock.SystemClock(), flow_process_groups.PROCESS_TABLE)
    return run({"early": early_script}, logs, settings)


class LockThatTellsWhenALaneWaitsOnIt:
    def __init__(self) -> None:
        self.held = threading.Lock()
        self.lane_waits = threading.Event()

    def __enter__(self) -> bool:
        if self.held.locked() and not in_main_thread():
            self.lane_waits.set()
        return self.held.acquire()

    def __exit__(self, *details: object) -> None:
        self.held.release()


class EventThatStopsTheRunWhileALaneWaits(threading.Event):
    def __init__(self, lock: LockThatTellsWhenALaneWaitsOnIt, second_go: Path) -> None:
        super().__init__()
        self.lock = lock
        self.second_go = second_go
        self.stop_sent = threading.Event()

    def clear(self) -> None:
        super().clear()
        if in_main_thread() and not self.stop_sent.is_set():
            self.stop_while_a_lane_waits()

    def stop_while_a_lane_waits(self) -> None:
        self.stop_sent.set()
        self.second_go.touch()
        self.lock.lane_waits.wait(AWAIT_LIMIT_SECONDS)
        signal.raise_signal(STOP_SIGNAL)


def installer_of_a_waiter_that_stops_the_run(install: "Callable[[set[Future], str], _base._Waiter]", first_go: Path, second_go: Path) -> "Callable[[set[Future], str], _base._Waiter]":
    def install_a_waiter_that_stops_the_run(futures: "set[Future]", return_when: str) -> _base._Waiter:
        waiter = install(futures, return_when)
        waiter.lock = LockThatTellsWhenALaneWaitsOnIt()
        waiter.event = EventThatStopsTheRunWhileALaneWaits(waiter.lock, second_go)
        first_go.touch()
        return waiter

    return install_a_waiter_that_stops_the_run


def finishing_suite(arguments: "list[str]") -> int:
    first_script, second_script, logs, first_go, second_go = arguments
    _base._create_and_install_waiters = installer_of_a_waiter_that_stops_the_run(_base._create_and_install_waiters, Path(first_go), Path(second_go))
    settings = flow_suites.settings_from({LANES_VARIABLE: TWO_LANES}, flow_clock.SystemClock(), flow_process_groups.PROCESS_TABLE)
    return run({"first": first_script, "second": second_script}, logs, settings)


def listing_hang(arguments: "list[str]") -> int:
    suite_script, logs, missing_process_table = arguments
    settings = flow_suites.settings_from({}, flow_clock.SystemClock(), flow_process_groups.ProcessTable(Path(missing_process_table)))
    return run({"listing": suite_script}, logs, settings)


RUNNERS = {"late-start": late_start, "early-stop": early_stop, "finishing-suite": finishing_suite, "listing-hang": listing_hang}


def main(arguments: "list[str]") -> int:
    runner, *runner_arguments = arguments
    return RUNNERS[runner](runner_arguments)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
