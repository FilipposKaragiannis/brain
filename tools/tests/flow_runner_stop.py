"""Checks that a TERM, INT or HUP stops Brain's Flow suite runner in time and leaves no suite
behind. flow-runner-stop.sh builds the throwaway project and passes its folder, its base commit, a
scratch folder and the grace time Flow's verify gives a stopped run. Each scenario writes stub
suites, starts flow_suites.py or a runner from flow_runner_stop_harness.py, stops it, and gives one
line per check: 'ok <name>', or 'FAIL <name>' with what it got and the runner's output. Exits 1 on
any FAIL."""
import os
import signal
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.append(str(Path(__file__).resolve().parent))
from flow_runner_stop_processes import (  # noqa: E402
    ENDED,
    Fixture,
    Stopped,
    end_a_self_stopping_run,
    recorded,
    start_flow_run,
    start_harness,
    state_killing_a_survivor,
    states_killing_survivors,
    stop_once_ready,
)

SUITE_FOLDER = Path("plugins/flow/tests")
STOP_GRACE_VARIABLE = "FLOW_SUITE_STOP_GRACE_SECONDS"
CHILD_SECONDS = 120
GO_POLL_SECONDS = 0.1
GO_LIMIT_TICKS = 300
EXECUTABLE_MODE = 0o755
SIGNAL_EXIT_BASE = 128
STOP_GRACE_SECONDS = 2
STOP_MARGIN_SECONDS = 3
CLEANUP_SECONDS = 1
MANY_STOP_GRACE_SECONDS = 4
ONE_GRACE_MARGIN_SECONDS = 2
LANE_HOLD_SECONDS = 1
LATE_START_GRACE_SECONDS = 5
DEAF_SUITES = ("sessions", "base-claim", "verify-scope")
ONE_LINE = 1
NO_TRACEBACK = 0
EVERY_DEAF_SUITE_ENDED = " ".join(ENDED for _ in DEAF_SUITES)


@dataclass(frozen=True)
class Check:
    name: str
    got: str
    expected: str
    output: str


def check(name: str, got: object, expected: object, stopped: Stopped) -> Check:
    return Check(name, str(got), str(expected), stopped.output)


def exit_code_of(stop_signal: signal.Signals) -> int:
    return SIGNAL_EXIT_BASE + stop_signal


def write_suite(fixture: Fixture, name: str, body: str) -> None:
    (fixture.project / SUITE_FOLDER / f"{name}.sh").write_text(body)


def write_stub(fixture: Fixture, name: str, body: str) -> Path:
    script = fixture.work / f"{name}.sh"
    script.write_text(body)
    return script


def make_log_folder(fixture: Fixture, name: str) -> Path:
    logs = fixture.work / f"{name}-logs"
    logs.mkdir()
    return logs


def script_ending_once(go_file: Path) -> str:
    return f'ticks=0\nuntil [ -f "{go_file}" ] || [ "$ticks" -ge {GO_LIMIT_TICKS} ]; do sleep {GO_POLL_SECONDS}; ticks=$((ticks + 1)); done\n'


def ended_in_time(stopped: Stopped, bound_seconds: float, verdict: str) -> str:
    return verdict if stopped.state == ENDED and stopped.seconds < bound_seconds else f"{stopped.state} after {stopped.seconds:.1f}s"


def stopped_lines(stopped: Stopped, name: str) -> int:
    return stopped.output.splitlines().count(f"flow: {name} stopped")


def ignoring_term(fixture: Fixture) -> "list[Check]":
    work = fixture.work
    write_suite(fixture, "sessions", f'trap \'\' TERM\necho "  ok   Stub_DeafToTerm"\necho $$ > "{work}/deaf-suite"\n: > "{work}/deaf-suite-ready"\nsleep {CHILD_SECONDS}\n')
    write_suite(fixture, "base-claim", f'sh -c \'trap "" TERM; echo $$ > "{work}/deaf-descendant"; : > "{work}/deaf-descendant-ready"; exec sleep {CHILD_SECONDS}\' &\nsleep {CHILD_SECONDS}\n')
    write_suite(fixture, "verify-scope", f'(trap \'sleep {CLEANUP_SECONDS}; echo cleaned > "{work}/cleanup"; exit 0\' TERM; : > "{work}/cleaning-suite-ready"; sleep {CHILD_SECONDS}) &\nsleep {CHILD_SECONDS}\n')
    ready = [work / "deaf-suite-ready", work / "deaf-descendant-ready", work / "cleaning-suite-ready"]
    stopped = stop_once_ready(start_flow_run({STOP_GRACE_VARIABLE: str(STOP_GRACE_SECONDS)}, fixture), ready, [signal.SIGTERM], fixture)
    suite_state, descendant_state = states_killing_survivors([recorded(work / "deaf-suite"), recorded(work / "deaf-descendant")])
    return [
        check("RunnerGivenTermWhileASuiteIgnoresTerm_EndsWithinTheGraceTime because a suite deaf to TERM must not hold up cancellation", ended_in_time(stopped, STOP_GRACE_SECONDS + STOP_MARGIN_SECONDS, "within-grace"), "within-grace", stopped),
        check("RunnerGivenTermWhileASuiteIgnoresTerm_EndsThatSuite because a stopped run leaves no suite behind", suite_state, ENDED, stopped),
        check("RunnerGivenTermWhileADescendantIgnoresTerm_EndsThatDescendant because a stopped run leaves no check behind", descendant_state, ENDED, stopped),
        check("RunnerGivenTermWhileASuiteIgnoresTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped", stopped.code, exit_code_of(signal.SIGTERM), stopped),
        check("RunnerGivenTermWhileASuiteIgnoresTerm_NamesThatSuiteAsStopped because the owner must see where the run stood", stopped_lines(stopped, "sessions"), ONE_LINE, stopped),
        check("RunnerGivenTermWhileASuiteCleansUp_LetsItFinishItsCleanup because the grace time lasts until the whole group is gone", recorded(work / "cleanup"), "cleaned", stopped),
    ]


def stop_a_run_of_deaf_suites(grace: "Mapping[str, str]", stop_signals: "Sequence[signal.Signals]", fixture: Fixture) -> "tuple[Stopped, str]":
    files = {name: (fixture.work / f"deaf-{name}", fixture.work / f"deaf-{name}-ready") for name in DEAF_SUITES}
    for name, (pid_file, ready_file) in files.items():
        write_suite(fixture, name, f'trap \'\' TERM\necho $$ > "{pid_file}"\n: > "{ready_file}"\nsleep {CHILD_SECONDS}\n')
    stopped = stop_once_ready(start_flow_run(grace, fixture), [ready_file for _, ready_file in files.values()], stop_signals, fixture)
    states = " ".join(states_killing_survivors([recorded(pid_file) for pid_file, _ in files.values()]))
    for path in (path for pair in files.values() for path in pair):
        path.unlink(missing_ok=True)
    return stopped, states


def several_ignoring_term(fixture: Fixture) -> "list[Check]":
    stopped, states = stop_a_run_of_deaf_suites({STOP_GRACE_VARIABLE: str(MANY_STOP_GRACE_SECONDS)}, [signal.SIGINT], fixture)
    return [
        check("RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsWithinOneGraceTime because all running suites share one grace time and not one each", ended_in_time(stopped, MANY_STOP_GRACE_SECONDS + ONE_GRACE_MARGIN_SECONDS, "within-grace"), "within-grace", stopped),
        check("RunnerGivenIntWhileSeveralSuitesIgnoreTerm_EndsEverySuite because a stopped run leaves no suite behind", states, EVERY_DEAF_SUITE_ENDED, stopped),
        check("RunnerGivenIntWhileSeveralSuitesIgnoreTerm_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see which signal stopped the run", stopped.code, exit_code_of(signal.SIGINT), stopped),
    ]


def more_signals_late_in_the_grace(fixture: Fixture) -> "list[Check]":
    stopped, states = stop_a_run_of_deaf_suites({STOP_GRACE_VARIABLE: str(MANY_STOP_GRACE_SECONDS)}, [signal.SIGHUP, signal.SIGTERM, signal.SIGINT], fixture)
    return [
        check("RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsWithinOneGraceTime because a later signal must not restart or lengthen the wait", ended_in_time(stopped, MANY_STOP_GRACE_SECONDS + ONE_GRACE_MARGIN_SECONDS, "within-grace"), "within-grace", stopped),
        check("RunnerGivenHupThenMoreSignalsLateInTheGrace_ExitsWith128PlusTheFirstSignalNumber because a later signal must not stop the run a second time", stopped.code, exit_code_of(signal.SIGHUP), stopped),
        check("RunnerGivenHupThenMoreSignalsLateInTheGrace_PrintsNoTraceback because a signal must not raise from inside the handler", stopped.output.count("Traceback"), NO_TRACEBACK, stopped),
        check("RunnerGivenHupThenMoreSignalsLateInTheGrace_EndsEverySuite because a stopped run leaves no suite behind", states, EVERY_DEAF_SUITE_ENDED, stopped),
    ]


def default_grace(fixture: Fixture) -> "list[Check]":
    stopped, states = stop_a_run_of_deaf_suites({}, [signal.SIGTERM], fixture)
    return [
        check("RunnerGivenTermWithTheDefaultGrace_EndsBeforeVerifyKillsIt because verify kills only the runner and each suite runs in a session of its own", ended_in_time(stopped, fixture.verify_grace_seconds, "before-verify"), "before-verify", stopped),
        check("RunnerGivenTermWithTheDefaultGrace_EndsEverySuite because a stopped run leaves no suite behind", states, EVERY_DEAF_SUITE_ENDED, stopped),
    ]


def lane_starting_after_the_stop(fixture: Fixture) -> "list[Check]":
    first = write_stub(fixture, "first-suite", f"sleep {LANE_HOLD_SECONDS}\n")
    late = write_stub(fixture, "late-suite", f'trap "" TERM\necho $$ > "{fixture.work}/late-suite"\nsleep {CHILD_SECONDS}\n')
    stopped = end_a_self_stopping_run(start_harness("late-start", [first, late, make_log_folder(fixture, "late"), str(LATE_START_GRACE_SECONDS)], {}, fixture), fixture)
    return [
        check("SuiteALaneStartsAfterTheStop_EndsTheRunWithoutAGraceTime because the runner must not wait on a suite it never let run", ended_in_time(stopped, LANE_HOLD_SECONDS + LATE_START_GRACE_SECONDS, "at-once"), "at-once", stopped),
        check("SuiteALaneStartsAfterTheStop_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped", stopped.code, exit_code_of(signal.SIGTERM), stopped),
        check("SuiteALaneStartsAfterTheStop_LeavesNoProcessBehind because a stopped run leaves no suite behind", state_killing_a_survivor(fixture.work / "late-suite"), ENDED, stopped),
    ]


def handing_out_suites(fixture: Fixture) -> "list[Check]":
    early = write_stub(fixture, "early-suite", f'echo $$ > "{fixture.work}/early-suite"\nsleep {CHILD_SECONDS}\n')
    stopped = end_a_self_stopping_run(start_harness("early-stop", [early, make_log_folder(fixture, "early")], {}, fixture), fixture)
    return [
        check("RunnerGivenTermWhileItHandsASuiteToALane_Ends because a stop that lands as the suites are handed out must not hang the run", stopped.state, ENDED, stopped),
        check("RunnerGivenTermWhileItHandsASuiteToALane_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped", stopped.code, exit_code_of(signal.SIGTERM), stopped),
        check("RunnerGivenTermWhileItHandsASuiteToALane_LeavesNoProcessBehind because a stopped run leaves no suite behind", state_killing_a_survivor(fixture.work / "early-suite"), ENDED, stopped),
    ]


def collecting_a_finishing_suite(fixture: Fixture) -> "list[Check]":
    first_go, second_go = fixture.work / "first-go", fixture.work / "second-go"
    first, second = write_stub(fixture, "first-finishing-suite", script_ending_once(first_go)), write_stub(fixture, "second-finishing-suite", script_ending_once(second_go))
    stopped = end_a_self_stopping_run(start_harness("finishing-suite", [first, second, make_log_folder(fixture, "finishing"), first_go, second_go], {}, fixture), fixture)
    return [
        check("RunnerGivenTermWhileItCollectsAFinishingSuite_Ends because a stop that lands as a suite finishes must not deadlock the run", stopped.state, ENDED, stopped),
        check("RunnerGivenTermWhileItCollectsAFinishingSuite_ExitsWith128PlusTheSignalNumber because a caller reads the exit code to see the run was stopped", stopped.code, exit_code_of(signal.SIGTERM), stopped),
    ]


def hanging_process_listing(fixture: Fixture) -> "list[Check]":
    listing_folder = fixture.work / "hanging-ps"
    listing_folder.mkdir()
    (listing_folder / "ps").write_text(f"#!/bin/sh\nexec sleep {CHILD_SECONDS}\n")
    (listing_folder / "ps").chmod(EXECUTABLE_MODE)
    descendant, ready = fixture.work / "listing-descendant", fixture.work / "listing-descendant-ready"
    suite = write_stub(fixture, "listing-suite", f'sh -c \'trap "" TERM; echo $$ > "{descendant}"; : > "{ready}"; exec sleep {CHILD_SECONDS}\' &\nsleep {CHILD_SECONDS}\n')
    runner = start_harness("listing-hang", [suite, make_log_folder(fixture, "listing"), fixture.work / "no-process-table"], {"PATH": f"{listing_folder}{os.pathsep}{os.environ['PATH']}"}, fixture)
    stopped = stop_once_ready(runner, [ready], [signal.SIGTERM], fixture)
    return [
        check("RunnerGivenTermWhileTheProcessListingHangs_EndsBeforeVerifyKillsIt because a look at the process listing must not outlast the grace time", ended_in_time(stopped, fixture.verify_grace_seconds, "before-verify"), "before-verify", stopped),
        check("RunnerGivenTermWhileTheProcessListingHangs_EndsTheDescendantDeafToTerm because a stopped run leaves no check behind", state_killing_a_survivor(descendant), ENDED, stopped),
    ]


SCENARIOS: "tuple[Callable[[Fixture], list[Check]], ...]" = (
    ignoring_term,
    several_ignoring_term,
    more_signals_late_in_the_grace,
    default_grace,
    lane_starting_after_the_stop,
    handing_out_suites,
    collecting_a_finishing_suite,
    hanging_process_listing,
)


def holds(outcome: Check) -> bool:
    return outcome.got == outcome.expected


def report(outcome: Check) -> str:
    return f"ok {outcome.name}" if holds(outcome) else f"FAIL {outcome.name}: got '{outcome.got}', expected '{outcome.expected}'\n{outcome.output}"


def main(arguments: "list[str]") -> int:
    project, base, work, verify_grace = arguments
    fixture = Fixture(Path(project), base, Path(work), int(verify_grace))
    outcomes: "list[Check]" = []
    for scenario in SCENARIOS:
        checked = scenario(fixture)
        print("\n".join(report(outcome) for outcome in checked), flush=True)
        outcomes.extend(checked)
    return 0 if all(holds(outcome) for outcome in outcomes) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
