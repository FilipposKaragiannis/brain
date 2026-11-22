"""The processes flow_runner_stop.py starts and watches: a Flow suite runner started on the
throwaway project, its stop by signal, how long it took to end with its exit code and output, and
whether the suite processes it left are still running, read for all of them from one process
listing per poll."""
import contextlib
import os
import signal
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

HARNESS = Path(__file__).resolve().parent / "flow_runner_stop_harness.py"
RUNNER = Path("tools/lib/flow_suites.py")
RUNNER_VARIABLE_PREFIX = "FLOW_SUITE_"
OUTPUT_FILE = "output"
POLL_SECONDS = 0.1
READY_LIMIT_SECONDS = 10
STATE_LIMIT_SECONDS = 5
PROCESS_LISTING_LIMIT_SECONDS = 10
LATER_SIGNAL_SECONDS = 3
NO_WAIT_SECONDS = 0
LISTING_PID_COLUMN = 0
LISTING_STATE_COLUMN = 1
LISTING_COLUMNS = 2
ZOMBIE_STATE = "Z"
ENDED = "ended"
RUNNING = "running"


@dataclass(frozen=True)
class Fixture:
    project: Path
    base: str
    work: Path
    verify_grace_seconds: int


@dataclass(frozen=True)
class Stopped:
    state: str
    seconds: float
    code: str
    output: str


def runner_environment(extra: "Mapping[str, str]") -> "dict[str, str]":
    inherited = {key: value for key, value in os.environ.items() if not key.startswith(RUNNER_VARIABLE_PREFIX)}
    return {**inherited, **extra}


def start_runner(command: "Sequence[str]", extra: "Mapping[str, str]", fixture: Fixture) -> subprocess.Popen:
    with (fixture.work / OUTPUT_FILE).open("wb") as output:
        return subprocess.Popen([sys.executable, "-I", "-B", *command], cwd=fixture.project, env=runner_environment(extra), stdout=output, stderr=subprocess.STDOUT)  # noqa: S603


def start_flow_run(extra: "Mapping[str, str]", fixture: Fixture) -> subprocess.Popen:
    return start_runner([str(fixture.project / RUNNER), "since", fixture.base], extra, fixture)


def start_harness(name: str, arguments: "Sequence[object]", extra: "Mapping[str, str]", fixture: Fixture) -> subprocess.Popen:
    return start_runner([str(HARNESS), name, *(str(argument) for argument in arguments)], extra, fixture)


def await_files(paths: "Sequence[Path]") -> None:
    deadline = time.monotonic() + READY_LIMIT_SECONDS
    while not all(path.exists() for path in paths) and time.monotonic() < deadline:
        time.sleep(POLL_SECONDS)


def ended_by(process: subprocess.Popen, deadline: float) -> bool:
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(POLL_SECONDS)
    return process.poll() is not None


def end_runner(runner: subprocess.Popen, since: float, fixture: Fixture) -> Stopped:
    ended = ended_by(runner, since + fixture.verify_grace_seconds)
    seconds = time.monotonic() - since
    runner.kill()
    code = runner.wait(timeout=STATE_LIMIT_SECONDS)
    return Stopped(ENDED if ended else RUNNING, seconds, str(code), (fixture.work / OUTPUT_FILE).read_text(errors="replace"))


def end_a_self_stopping_run(runner: subprocess.Popen, fixture: Fixture) -> Stopped:
    return end_runner(runner, time.monotonic(), fixture)


def send_later(runner: subprocess.Popen, later_signals: "Sequence[signal.Signals]") -> None:
    time.sleep(LATER_SIGNAL_SECONDS if later_signals else NO_WAIT_SECONDS)
    for later_signal in later_signals:
        with contextlib.suppress(ProcessLookupError):
            os.kill(runner.pid, later_signal)


def stop_once_ready(runner: subprocess.Popen, ready: "Sequence[Path]", stop_signals: "Sequence[signal.Signals]", fixture: Fixture) -> Stopped:
    first_signal, *later_signals = stop_signals
    await_files(ready)
    os.kill(runner.pid, first_signal)
    sent_at = time.monotonic()
    send_later(runner, later_signals)
    return end_runner(runner, sent_at, fixture)


def listed_states() -> "dict[str, str]":
    listing = subprocess.run(["ps", "-A", "-o", "pid=,stat="], capture_output=True, timeout=PROCESS_LISTING_LIMIT_SECONDS, check=False)  # noqa: S603, S607
    rows = (line.split() for line in listing.stdout.decode(errors="replace").splitlines())
    return {row[LISTING_PID_COLUMN]: row[LISTING_STATE_COLUMN] for row in rows if len(row) == LISTING_COLUMNS}


def running_among(pids: "Sequence[str]") -> "list[str]":
    states = listed_states()
    return [pid for pid in pids if not states.get(pid, ZOMBIE_STATE).startswith(ZOMBIE_STATE)]


def kill_process(pid: str) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.kill(int(pid), signal.SIGKILL)


def states_killing_survivors(pids: "Sequence[str]") -> "tuple[str, ...]":
    deadline = time.monotonic() + STATE_LIMIT_SECONDS
    running = running_among(pids)
    while running and time.monotonic() < deadline:
        time.sleep(POLL_SECONDS)
        running = running_among(pids)
    for pid in running:
        kill_process(pid)
    return tuple(RUNNING if pid in running else ENDED for pid in pids)


def recorded(path: Path) -> str:
    return path.read_text().strip() if path.exists() else ""


def state_killing_a_survivor(pid_file: Path) -> str:
    states = states_killing_survivors([recorded(pid_file)]) if pid_file.exists() else (ENDED,)
    return " ".join(states)
