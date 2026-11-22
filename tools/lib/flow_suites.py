"""Select Brain's Flow tests and run independent suites in their own sandboxes.

FLOW_SUITE_LANES sets how many suites run at once, 3 when unset.
"""
import json
import os
import subprocess
import sys
import time
from collections.abc import Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
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


def commands(root):
    directory = root / TESTS
    suites = {"inline": ("sh", directory / "run.sh", "inline")}
    for file in sorted(directory.glob("*.sh")):
        if file.name.startswith(("_", "fake-")) or file.name == "run.sh":
            continue
        if file.stem == "adapter-contract":
            for adapter in ADAPTERS:
                suites["contract-" + adapter] = ("sh", file, adapter)
        elif file.stem not in suites and file.stem != "verify":
            suites[file.stem] = ("sh", file)
        else:
            raise ValueError(f"duplicate Flow suite name: {file.stem}")
    return suites


def changed_paths(root, base):
    def git(*arguments):
        return subprocess.check_output(("git", *arguments), cwd=root, stderr=subprocess.PIPE)

    committed = git("diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--")
    working = git("diff", "--no-renames", "--name-only", "-z", "HEAD", "--")
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    return {Path(os.fsdecode(name)) for name in (committed + working + untracked).split(b"\0") if name}


def affected(path, suites):
    if path in VERIFY_INPUTS:
        return {"verify", "base-claim", "base-readers"} | {name for name in suites if name.startswith("verify-")}
    if path == TESTS / "_verify_fixture.sh":
        return {name for name in suites if name.startswith("verify-")}
    if path == TESTS / "_base_fixture.sh":
        return set(suites) - {"inline"}
    if path == TESTS / "adapter-contract.sh":
        return {"contract-" + adapter for adapter in ADAPTERS}
    if path.parent == TESTS and path.suffix == ".sh" and path.stem in suites:
        return {path.stem}
    return set(suites)


def flow_inputs(root):
    config = json.loads((root / ".standards/config.json").read_text(encoding="utf-8"))
    entry = next(check for check in config["test"] if check["name"] == "flow")
    return [pattern.replace("**/", "*").replace("**", "*") for pattern in entry["paths"]]


def matches(path: Path, patterns: Sequence[str]) -> bool:
    return any(fnmatchcase(path.as_posix(), pattern) for pattern in patterns)


def selection(root, base, suites):
    if base is None:
        return set(suites)
    try:
        paths = changed_paths(root, base)
    except subprocess.CalledProcessError:
        print("flow: no comparison base available, running every suite", flush=True)
        return set(suites)
    patterns = flow_inputs(root)
    relevant = (path for path in paths if matches(path, patterns) and not matches(path, UNRELATED_TO_TESTS))
    selected = set().union(*(affected(path, suites) for path in relevant))
    if "inline" in selected:
        selected.discard("verify")
    return selected


def run_suite(command, log):
    started = time.monotonic()
    environment = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "LANG") if key in os.environ}
    with log.open("wb") as output:
        result = subprocess.run(command, env=environment, stdout=output, stderr=subprocess.STDOUT)
    return result.returncode, time.monotonic() - started


def print_output(name: str, log: Path) -> None:
    prefix = f"[{name}] ".encode()
    with log.open("rb") as output:
        for line in output:
            sys.stdout.buffer.write(prefix + line.rstrip(b"\n") + b"\n")
    sys.stdout.buffer.flush()


def run_selected(suites, directory, lanes: int) -> "list[str]":
    failed = []
    with ThreadPoolExecutor(max_workers=lanes) as workers:
        running = {workers.submit(run_suite, command, directory / name): name for name, command in suites.items()}
        for finished in as_completed(running):
            name = running[finished]
            code, elapsed = finished.result()
            print_output(name, directory / name)
            print(f"flow: {name} {'FAIL' if code else 'pass'} ({elapsed:.1f}s)", flush=True)
            if code:
                failed.append(name)
    return sorted(failed)


def lane_count(environment: Mapping[str, str]) -> int:
    value = environment.get(LANES_VARIABLE, str(DEFAULT_LANES))
    if not (value.isascii() and value.isdigit() and int(value) >= 1):
        sys.exit(f"flow: {LANES_VARIABLE} takes a whole number from 1, not '{value}'")
    return int(value)


def run(root, base, lanes: int):
    suites = commands(root)
    selected = selection(root, base, suites)
    suites["verify"] = ("sh", root / TESTS / "run.sh", "verify")
    if not selected:
        print("flow: no Flow test inputs changed", flush=True)
        return 0
    missing = selected - suites.keys()
    if missing:
        sys.exit("flow: missing selected suites: " + ", ".join(sorted(missing)))
    planned = {name: command for name, command in suites.items() if name in selected}
    print("flow: selected " + ", ".join(planned), flush=True)
    with TemporaryDirectory(prefix="flow-suites-") as logs:
        failed = run_selected(planned, Path(logs), lanes)
    print("flow: failed in " + ", ".join(failed) if failed else "flow: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["all"]:
        sys.exit(run(ROOT, None, lane_count(os.environ)))
    if len(sys.argv) == 3 and sys.argv[1] == "since":
        sys.exit(run(ROOT, sys.argv[2], lane_count(os.environ)))
    sys.exit("usage: flow_suites.py all | since <base commit>")
