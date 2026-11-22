"""Split Brain's Flow suites into shards balanced by the durations in flow_suite_durations.json.

The table holds the seconds each suite took in CI. The longest suite goes first, each to the shard
with the least time so far. A suite the table does not name counts as the mean of the table, so it
still lands in exactly one shard. The split depends only on the suite names and the table.
"""
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from statistics import fmean

from flow_selection import Checkout, SuiteName

_TABLE = Path("tools/lib/flow_suite_durations.json")
_SECONDS_WHEN_NOTHING_IS_MEASURED = 1.0


@dataclass(frozen=True)
class Shard:
    number: int
    count: int


WHOLE_RUN = Shard(1, 1)


def _measured_seconds(checkout: Checkout) -> "Mapping[SuiteName, float]":
    table = json.loads((checkout.folder / _TABLE).read_text(encoding="utf-8"))
    return {SuiteName(name): float(seconds) for name, seconds in table.items()}


def suites_in(shard: Shard, suites: "frozenset[SuiteName]", checkout: Checkout) -> "frozenset[SuiteName]":
    measured = _measured_seconds(checkout)
    unmeasured = fmean(measured.values()) if measured else _SECONDS_WHEN_NOTHING_IS_MEASURED
    seconds = {name: measured.get(name, unmeasured) for name in suites}
    loads = [0.0] * shard.count
    chosen = set()
    for name in sorted(suites, key=lambda name: (-seconds[name], name)):
        lightest = min(range(shard.count), key=lambda index: (loads[index], index))
        loads[lightest] += seconds[name]
        if lightest == shard.number - 1:
            chosen.add(name)
    return frozenset(chosen)
