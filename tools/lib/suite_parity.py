"""Prove that no check is lost when a test runner is cut into suite files.

    python3 -I tools/lib/suite_parity.py inventory --shape old|new --log FILE --output FILE [...]
    python3 -I tools/lib/suite_parity.py compare --baseline FILE --candidate FILE --mapping FILE

inventory reads a test log and writes a JSON inventory: for each result line, the unit it
belongs to, its name, its outcome and how often that triple occurs. A result line is
"  ok   <name>", "  FAIL <name>" or "  skip <name>". Two log shapes:

  old  The runner prints a section header line, then one result line per check. A child run it
       starts prints only one summary line there, so each child's own output comes in with
       --child NAME=FILE. --headers FILE lists the section header lines, one per line; a line
       is a header only when it is listed, so a stray error line never starts a section. The
       unit of an inline result is its section; the unit of a child result is NAME.
  new  Every line of a suite's output is prefixed with "[<suite name>] ". The unit of a result
       is its suite. Lines with no prefix are the runner's own and are ignored.

--start-after LINE and --stop-at LINE cut the part of a log that holds the checks, by an exact
line. --label TEXT is kept in the inventory to say where it came from.

compare reads a baseline inventory, a candidate inventory and a mapping file, and reports every
difference between the multisets of (suite, name, outcome) with their counts. The exit status is
0 only with no unexplained difference, 1 when there are some and 2 on an input it cannot read.
The mapping file is JSON:

  sections    old section header -> new suite
  children    old child name -> new suite
  wrappers    a list of {"section", "name_prefix", "child"}: the summary line the old runner
              printed for a child. Each must match exactly one baseline result and its child
              must exist. A wrapper line is never counted as a check.
  allowances  a list of {"kind", "suite", "name", "reason"}: a difference the move is meant to
              make, with the suite the check ends in. It is listed as explained. One that
              matches nothing is itself reported.

Differences: loss (fewer than in the baseline), addition (a name the baseline lacks),
duplicate (more than in the baseline), skip (a skipped check the baseline lacks), failure (a
failed check the baseline lacks), moved (a loss in one suite and an addition of the same name
in another), unmapped (a baseline unit the mapping does not route), wrapper (a wrapper entry
that does not hold), stale (an allowance that matches nothing).

Normalisation. Only line framing is normalised, because each rule below is shown to vary and
no check name has been shown to vary:
  1. A byte order mark at the start of a line is removed (the GitHub log starts with one).
  2. The GitHub log prefix "<job>\\t<step>\\t<timestamp> " is removed from a line.
  3. A trailing carriage return and trailing blanks are removed.
A name is otherwise compared as printed.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Set, Tuple

INVENTORY_FORMAT = "flow-parity-inventory/1"
KIND_SECTION = "section"
KIND_CHILD = "child"
KIND_SUITE = "suite"
UNIT_KINDS = (KIND_SECTION, KIND_CHILD, KIND_SUITE)
SHAPE_OLD = "old"
SHAPE_NEW = "new"
OUTCOME_OK = "ok"
OUTCOME_FAIL = "FAIL"
OUTCOME_SKIP = "skip"
OUTCOMES = (OUTCOME_OK, OUTCOME_FAIL, OUTCOME_SKIP)
DIFFERENCE_KINDS = ("loss", "addition", "duplicate", "skip", "failure", "moved")
EXIT_CLEAN = 0
EXIT_DIFFERENT = 1
EXIT_BAD_INPUT = 2
BYTE_ORDER_MARK = chr(0xFEFF)
CI_PREFIX = re.compile(r"^[^\t]*\t[^\t]*\t\d{4}-\d{2}-\d{2}T[\d:.]+Z ?(.*)$")
RESULT_LINE = re.compile(r"^  (ok   |FAIL |skip )(.*)$")
SUITE_PREFIX = re.compile(r"^\[([^\]]+)\] (.*)$")
CHILD_ARGUMENT = re.compile(r"^([^=]+)=(.+)$")


@dataclass(frozen=True)
class Outcome:
    outcome: str
    name: str


@dataclass(frozen=True)
class Result:
    kind: str
    unit: str
    name: str
    outcome: str


@dataclass(frozen=True)
class Entry:
    kind: str
    unit: str
    name: str
    outcome: str
    count: int


@dataclass(frozen=True)
class Inventory:
    label: str
    shape: str
    entries: Tuple[Entry, ...]


@dataclass(frozen=True)
class InventoryLoad:
    inventory: Inventory
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class Window:
    lines: Tuple[str, ...]
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class ParsedLog:
    results: Tuple[Result, ...]
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class Route:
    kind: str
    unit: str
    suite: str


@dataclass(frozen=True)
class Wrapper:
    section: str
    name_prefix: str
    child: str


@dataclass(frozen=True)
class Allowance:
    kind: str
    suite: str
    name: str
    reason: str


@dataclass(frozen=True)
class Mapping:
    routes: Tuple[Route, ...]
    wrappers: Tuple[Wrapper, ...]
    allowances: Tuple[Allowance, ...]


@dataclass(frozen=True)
class MappingLoad:
    mapping: Mapping
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class WrapperLoad:
    wrappers: Tuple[Wrapper, ...]
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class AllowanceLoad:
    allowances: Tuple[Allowance, ...]
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class UnitRef:
    kind: str
    unit: str


@dataclass(frozen=True)
class Count:
    suite: str
    name: str
    outcome: str
    count: int


@dataclass(frozen=True)
class WrapperHits:
    wrapper: Wrapper
    hits: int


@dataclass(frozen=True)
class MappedInventory:
    counts: Tuple[Count, ...]
    wrappers: Tuple[WrapperHits, ...]
    unmapped: Tuple[UnitRef, ...]


@dataclass(frozen=True)
class Difference:
    kind: str
    suite: str
    name: str
    outcome: str
    count: int
    detail: str


@dataclass(frozen=True)
class Explained:
    difference: Difference
    reason: str


@dataclass(frozen=True)
class Allowed:
    unexplained: Tuple[Difference, ...]
    explained: Tuple[Explained, ...]


@dataclass(frozen=True)
class Report:
    unexplained: Tuple[Difference, ...]
    explained: Tuple[Explained, ...]
    checks: int
    suites: int
    wrappers: int


def unframe(raw: str) -> str:
    """The line with the byte order mark, the GitHub log prefix and trailing blanks removed."""
    line = raw.rstrip("\r\n")
    if line.startswith(BYTE_ORDER_MARK):
        line = line[len(BYTE_ORDER_MARK):]
    prefixed = CI_PREFIX.match(line)
    if prefixed:
        line = prefixed.group(1)
    return line.rstrip()


def read_lines(path: str) -> List[str]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return [unframe(raw) for raw in handle]


def read_header_lines(path: str) -> List[str]:
    with open(path, encoding="utf-8") as handle:
        return [raw.rstrip("\r\n") for raw in handle if raw.strip()]


def result_of(line: str) -> Optional[Outcome]:
    """The outcome and name of a result line, or None for any other line."""
    matched = RESULT_LINE.match(line)
    if not matched:
        return None
    return Outcome(matched.group(1).strip(), matched.group(2))


def cut_window(lines: Sequence[str], start_after: str, stop_at: str) -> Window:
    """The lines between the two marker lines, and a problem for each marker not found."""
    problems: List[str] = []
    kept = list(lines)
    if start_after and start_after in kept:
        kept = kept[kept.index(start_after) + 1:]
    elif start_after:
        problems.append("--start-after line not found: %s" % start_after)
    if stop_at and stop_at in kept:
        kept = kept[:kept.index(stop_at)]
    elif stop_at:
        problems.append("--stop-at line not found: %s" % stop_at)
    return Window(tuple(kept), tuple(problems))


def parse_old_log(lines: Sequence[str], headers: Sequence[str]) -> ParsedLog:
    """Each result line of an old-shape log, in the section the last listed header opened."""
    known = set(headers)
    section = ""
    results: List[Result] = []
    problems: List[str] = []
    for line in lines:
        found = result_of(line)
        if line in known:
            section = line
        elif found is not None and section:
            results.append(Result(KIND_SECTION, section, found.name, found.outcome))
        elif found is not None:
            problems.append("result before any section header: %s" % found.name)
    return ParsedLog(tuple(results), tuple(problems))


def parse_child_log(lines: Sequence[str], child: str) -> ParsedLog:
    """Each result line of one child run's own output."""
    found = [(result_of(line)) for line in lines]
    return ParsedLog(tuple(Result(KIND_CHILD, child, f.name, f.outcome) for f in found if f is not None), ())


def parse_new_log(lines: Sequence[str]) -> ParsedLog:
    """Each result line of a new-shape log, in the suite its prefix names."""
    results: List[Result] = []
    for line in lines:
        prefixed = SUITE_PREFIX.match(line)
        found = result_of(prefixed.group(2)) if prefixed else None
        if prefixed and found is not None:
            results.append(Result(KIND_SUITE, prefixed.group(1), found.name, found.outcome))
    return ParsedLog(tuple(results), ())


def build_inventory(label: str, shape: str, results: Sequence[Result]) -> Inventory:
    counted = Counter((r.kind, r.unit, r.name, r.outcome) for r in results)
    entries = [Entry(kind, unit, name, outcome, count)
               for (kind, unit, name, outcome), count in sorted(counted.items())]
    return Inventory(label, shape, tuple(entries))


def render_inventory(inventory: Inventory) -> str:
    """The inventory as JSON text, one entry to a line so a change reads in a diff."""
    head = json.dumps({"format": INVENTORY_FORMAT, "label": inventory.label, "shape": inventory.shape})
    rows = [json.dumps({"kind": e.kind, "unit": e.unit, "name": e.name, "outcome": e.outcome, "count": e.count},
                       ensure_ascii=False) for e in inventory.entries]
    return '{"head": %s,\n"entries": [\n%s\n]}\n' % (head, ",\n".join(rows))


def parse_inventory(document: object) -> InventoryLoad:
    """An inventory read from decoded JSON, with a problem for each part that is not valid."""
    empty = Inventory("", "", ())
    if not isinstance(document, dict) or not isinstance(document.get("head"), dict):
        return InventoryLoad(empty, ("inventory has no head",))
    head = document["head"]
    rows = document.get("entries")
    if not isinstance(rows, list):
        return InventoryLoad(empty, ("inventory has no entries list",))
    problems: List[str] = []
    if head.get("format") != INVENTORY_FORMAT:
        problems.append("inventory format is not %s" % INVENTORY_FORMAT)
    parsed = [parse_entry(row) for row in rows]
    problems += ["inventory entry %d is not valid" % index for index, entry in enumerate(parsed) if entry is None]
    label = head.get("label") if isinstance(head.get("label"), str) else ""
    shape = head.get("shape") if isinstance(head.get("shape"), str) else ""
    entries = tuple(entry for entry in parsed if entry is not None)
    return InventoryLoad(Inventory(label, shape, entries), tuple(problems))


def parse_entry(row: object) -> Optional[Entry]:
    if not isinstance(row, dict):
        return None
    kind, unit, name = row.get("kind"), row.get("unit"), row.get("name")
    outcome, count = row.get("outcome"), row.get("count")
    if kind not in UNIT_KINDS or outcome not in OUTCOMES:
        return None
    if not isinstance(unit, str) or not isinstance(name, str):
        return None
    if not isinstance(count, int) or isinstance(count, bool) or count < 1:
        return None
    return Entry(kind, unit, name, outcome, count)


def parse_routes(document: Dict[str, object]) -> Tuple[List[Route], List[str]]:
    routes: List[Route] = []
    problems: List[str] = []
    for field, kind in (("sections", KIND_SECTION), ("children", KIND_CHILD)):
        pairs = document.get(field) or {}
        valid = isinstance(pairs, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in pairs.items())
        if not valid:
            problems.append("mapping %s is not an object of text to text" % field)
            continue
        routes.extend(Route(kind, unit, suite) for unit, suite in sorted(pairs.items()))
    return routes, problems


def parse_wrappers(rows: object) -> WrapperLoad:
    parsed = [parse_wrapper(row) for row in rows] if isinstance(rows, list) else []
    problems = ["mapping wrapper entry is not valid: %s" % json.dumps(row)
                for row, wrapper in zip(rows if isinstance(rows, list) else [], parsed) if wrapper is None]
    if rows is not None and not isinstance(rows, list):
        problems.append("mapping wrappers is not a list")
    return WrapperLoad(tuple(w for w in parsed if w is not None), tuple(problems))


def parse_allowances(rows: object) -> AllowanceLoad:
    parsed = [parse_allowance(row) for row in rows] if isinstance(rows, list) else []
    problems = ["mapping allowance is not valid: %s" % json.dumps(row)
                for row, allowance in zip(rows if isinstance(rows, list) else [], parsed) if allowance is None]
    if rows is not None and not isinstance(rows, list):
        problems.append("mapping allowances is not a list")
    return AllowanceLoad(tuple(a for a in parsed if a is not None), tuple(problems))


def parse_mapping(document: object) -> MappingLoad:
    """A mapping read from decoded JSON, with a problem for each part that is not valid."""
    if not isinstance(document, dict):
        return MappingLoad(Mapping((), (), ()), ("mapping is not an object",))
    routes, route_problems = parse_routes(document)
    wrappers = parse_wrappers(document.get("wrappers"))
    allowances = parse_allowances(document.get("allowances"))
    problems = tuple(route_problems) + wrappers.problems + allowances.problems
    return MappingLoad(Mapping(tuple(routes), wrappers.wrappers, allowances.allowances), problems)


def parse_wrapper(row: object) -> Optional[Wrapper]:
    if not isinstance(row, dict):
        return None
    section, prefix, child = row.get("section"), row.get("name_prefix"), row.get("child")
    if not (isinstance(section, str) and isinstance(prefix, str) and isinstance(child, str)):
        return None
    if not (section and prefix and child):
        return None
    return Wrapper(section, prefix, child)


def parse_allowance(row: object) -> Optional[Allowance]:
    if not isinstance(row, dict):
        return None
    kind, suite, name, reason = row.get("kind"), row.get("suite"), row.get("name"), row.get("reason")
    if kind not in DIFFERENCE_KINDS:
        return None
    if not (isinstance(suite, str) and isinstance(name, str) and isinstance(reason, str)):
        return None
    if not (suite and name and reason.strip()):
        return None
    return Allowance(kind, suite, name, reason)


def matching_wrapper(entry: Entry, wrappers: Sequence[Wrapper]) -> Optional[Wrapper]:
    if entry.kind != KIND_SECTION:
        return None
    for wrapper in wrappers:
        if entry.unit == wrapper.section and entry.name.startswith(wrapper.name_prefix):
            return wrapper
    return None


def map_inventory(inventory: Inventory, mapping: Mapping) -> MappedInventory:
    """The inventory's checks counted by new suite, with its wrapper lines set apart."""
    suites = {(route.kind, route.unit): route.suite for route in mapping.routes}
    counts: Counter = Counter()
    wrapper_hits: Counter = Counter()
    unmapped: Set[UnitRef] = set()
    for entry in inventory.entries:
        wrapper = matching_wrapper(entry, mapping.wrappers)
        suite = entry.unit if entry.kind == KIND_SUITE else suites.get((entry.kind, entry.unit), "")
        if wrapper is not None:
            wrapper_hits[wrapper] += entry.count
        elif suite:
            counts[(suite, entry.name, entry.outcome)] += entry.count
        else:
            unmapped.add(UnitRef(entry.kind, entry.unit))
    return MappedInventory(
        tuple(Count(suite, name, outcome, count) for (suite, name, outcome), count in sorted(counts.items())),
        tuple(WrapperHits(wrapper, wrapper_hits[wrapper]) for wrapper in mapping.wrappers),
        tuple(sorted(unmapped, key=lambda ref: (ref.kind, ref.unit))),
    )


def wrapper_differences(wrappers: Sequence[WrapperHits], inventory: Inventory) -> List[Difference]:
    children = {entry.unit for entry in inventory.entries if entry.kind == KIND_CHILD}
    found = [Difference("wrapper", w.wrapper.section, w.wrapper.name_prefix, OUTCOME_OK, w.hits,
                        "matches %d baseline results, not one" % w.hits) for w in wrappers if w.hits != 1]
    found += [Difference("wrapper", w.wrapper.section, w.wrapper.name_prefix, OUTCOME_OK, 0,
                         "child %s has no results in the baseline" % w.wrapper.child)
              for w in wrappers if w.wrapper.child not in children]
    return found


def excess_kind(before: int, outcome: str) -> str:
    if outcome == OUTCOME_SKIP:
        return "skip"
    if outcome == OUTCOME_FAIL:
        return "failure"
    return "duplicate" if before > 0 else "addition"


def count_differences(baseline: Counter, candidate: Counter) -> List[Difference]:
    found: List[Difference] = []
    for suite, name, outcome in sorted(set(baseline) | set(candidate)):
        before, after = baseline[(suite, name, outcome)], candidate[(suite, name, outcome)]
        detail = "baseline %d, candidate %d" % (before, after)
        if after < before:
            found.append(Difference("loss", suite, name, outcome, before - after, detail))
        elif after > before:
            found.append(Difference(excess_kind(before, outcome), suite, name, outcome, after - before, detail))
    return found


def pair_moves(found: Sequence[Difference]) -> List[Difference]:
    """The differences, with each loss that matches an addition in another suite merged into a move."""
    losses = [d for d in found if d.kind == "loss"]
    additions = [d for d in found if d.kind == "addition"]
    lost = {d: d.count for d in losses}
    added = {d: d.count for d in additions}
    moved: List[Difference] = []
    for loss, addition in [(l, a) for l in losses for a in additions
                           if l.name == a.name and l.outcome == a.outcome and l.suite != a.suite]:
        taken = min(lost[loss], added[addition])
        lost[loss] -= taken
        added[addition] -= taken
        if taken:
            moved.append(Difference("moved", addition.suite, addition.name, addition.outcome, taken,
                                    "from suite %s" % loss.suite))
    rest = [Difference(d.kind, d.suite, d.name, d.outcome, left, d.detail)
            for table in (lost, added) for d, left in table.items() if left]
    return rest + moved + [d for d in found if d.kind not in ("loss", "addition")]


def find_allowance(difference: Difference, allowances: Sequence[Allowance]) -> Optional[Allowance]:
    for allowance in allowances:
        if (allowance.kind, allowance.suite, allowance.name) == (difference.kind, difference.suite, difference.name):
            return allowance
    return None


def apply_allowances(found: Sequence[Difference], allowances: Sequence[Allowance]) -> Allowed:
    """The differences no allowance explains, and those one does, with the reason."""
    used: Set[Allowance] = set()
    unexplained: List[Difference] = []
    explained: List[Explained] = []
    for difference in found:
        allowance = find_allowance(difference, allowances)
        if allowance is None:
            unexplained.append(difference)
        else:
            used.add(allowance)
            explained.append(Explained(difference, allowance.reason))
    unexplained += [Difference("stale", a.suite, a.name, OUTCOME_OK, 0, "allowance for %s matches no difference" % a.kind)
                    for a in allowances if a not in used]
    return Allowed(tuple(unexplained), tuple(explained))


def sort_key(difference: Difference) -> Tuple[str, str, str, str]:
    return difference.kind, difference.suite, difference.name, difference.outcome


def compare_inventories(baseline: Inventory, candidate: Inventory, mapping: Mapping) -> Report:
    before = map_inventory(baseline, mapping)
    after = map_inventory(candidate, mapping)
    found = [Difference("unmapped", ref.unit, "", OUTCOME_OK, 0, "%s %s has no route in the mapping" % (ref.kind, ref.unit))
             for ref in before.unmapped + after.unmapped]
    found += wrapper_differences(before.wrappers, baseline)
    found += pair_moves(count_differences(counter_of(before), counter_of(after)))
    allowed = apply_allowances(found, mapping.allowances)
    return Report(
        tuple(sorted(allowed.unexplained, key=sort_key)),
        tuple(sorted(allowed.explained, key=lambda item: sort_key(item.difference))),
        sum(c.count for c in after.counts),
        len({c.suite for c in after.counts}),
        sum(w.hits for w in before.wrappers),
    )


def counter_of(mapped: MappedInventory) -> Counter:
    return Counter({(c.suite, c.name, c.outcome): c.count for c in mapped.counts})


def describe(difference: Difference) -> str:
    return "%s: %s: %s (%s)" % (difference.kind, difference.suite, difference.name or "-", difference.detail)


def render_report(report: Report) -> List[str]:
    lines = [describe(d) for d in report.unexplained]
    lines += ["explained %s (%s)" % (describe(e.difference), e.reason) for e in report.explained]
    if report.unexplained:
        lines.append("parity: %d unexplained differences, %d explained" % (len(report.unexplained), len(report.explained)))
    else:
        lines.append("parity: ok, %d checks in %d suites, %d wrapper lines mapped and not counted, %d differences explained"
                     % (report.checks, report.suites, report.wrappers, len(report.explained)))
    return lines


def read_json(path: str) -> object:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_text(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def collect_children(children: Sequence[str]) -> ParsedLog:
    results: List[Result] = []
    problems: List[str] = []
    for argument in children:
        matched = CHILD_ARGUMENT.match(argument)
        if matched:
            results.extend(parse_child_log(read_lines(matched.group(2)), matched.group(1)).results)
        else:
            problems.append("--child is not NAME=FILE: %s" % argument)
    return ParsedLog(tuple(results), tuple(problems))


def collect_old_results(arguments: argparse.Namespace) -> ParsedLog:
    if not arguments.headers:
        return ParsedLog((), ("--shape old needs --headers",))
    window = cut_window(read_lines(arguments.log), arguments.start_after, arguments.stop_at)
    inline = parse_old_log(window.lines, read_header_lines(arguments.headers))
    children = collect_children(arguments.child or [])
    return ParsedLog(inline.results + children.results, window.problems + inline.problems + children.problems)


def collect_new_results(arguments: argparse.Namespace) -> ParsedLog:
    window = cut_window(read_lines(arguments.log), arguments.start_after, arguments.stop_at)
    parsed = parse_new_log(window.lines)
    return ParsedLog(parsed.results, window.problems + parsed.problems)


def run_inventory(arguments: argparse.Namespace) -> int:
    parsed = collect_old_results(arguments) if arguments.shape == SHAPE_OLD else collect_new_results(arguments)
    if parsed.problems:
        report_problems(parsed.problems)
        return EXIT_BAD_INPUT
    inventory = build_inventory(arguments.label, arguments.shape, parsed.results)
    write_text(arguments.output, render_inventory(inventory))
    return EXIT_CLEAN


def run_compare(arguments: argparse.Namespace) -> int:
    baseline = parse_inventory(read_json(arguments.baseline))
    candidate = parse_inventory(read_json(arguments.candidate))
    mapping = parse_mapping(read_json(arguments.mapping))
    problems = baseline.problems + candidate.problems + mapping.problems
    if problems:
        report_problems(problems)
        return EXIT_BAD_INPUT
    report = compare_inventories(baseline.inventory, candidate.inventory, mapping.mapping)
    for line in render_report(report):
        print(line)
    return EXIT_DIFFERENT if report.unexplained else EXIT_CLEAN


def report_problems(problems: Sequence[str]) -> None:
    for problem in problems:
        print("suite_parity: %s" % problem, file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="suite_parity.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    inventory = commands.add_parser("inventory", help="write an inventory from a log",
                                    description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    inventory.add_argument("--shape", required=True, choices=(SHAPE_OLD, SHAPE_NEW))
    inventory.add_argument("--log", required=True)
    inventory.add_argument("--output", required=True)
    inventory.add_argument("--headers", default="")
    inventory.add_argument("--child", action="append", default=None)
    inventory.add_argument("--start-after", default="")
    inventory.add_argument("--stop-at", default="")
    inventory.add_argument("--label", default="")
    compare = commands.add_parser("compare", help="compare two inventories through a mapping",
                                  description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    compare.add_argument("--baseline", required=True)
    compare.add_argument("--candidate", required=True)
    compare.add_argument("--mapping", required=True)
    return parser


def main(argv: Sequence[str]) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "inventory":
            return run_inventory(arguments)
        return run_compare(arguments)
    except (OSError, json.JSONDecodeError) as failure:
        print("suite_parity: %s" % failure, file=sys.stderr)
        return EXIT_BAD_INPUT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
