"""Split Brain's Flow suites into shards balanced by the seconds in flow_suite_durations.json."""
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from statistics import fmean

from flow_selection import Checkout, SuiteName

_TABLE = Path("tools/lib/flow_suite_durations.json")
_SECONDS_WHEN_NOTHING_IS_MEASURED = 1.0
_FIRST_SHARD_NUMBER = 1


@dataclass(frozen=True)
class Shard:
    number: int
    count: int


WHOLE_RUN = Shard(_FIRST_SHARD_NUMBER, 1)


def _measured_seconds(checkout: Checkout) -> "Mapping[SuiteName, float]":
    table = json.loads((checkout.folder / _TABLE).read_text(encoding="utf-8"))
    return {SuiteName(name): float(seconds) for name, seconds in table.items()}


def _expected_seconds(suites: "frozenset[SuiteName]", checkout: Checkout) -> "Mapping[SuiteName, float]":
    measured = _measured_seconds(checkout)
    mean_of_measured = fmean(measured.values()) if measured else _SECONDS_WHEN_NOTHING_IS_MEASURED
    return {name: measured.get(name, mean_of_measured) for name in suites}


def suites_in(shard: Shard, suites: "frozenset[SuiteName]", checkout: Checkout) -> "frozenset[SuiteName]":
    seconds = _expected_seconds(suites, checkout)
    loads = [0.0] * shard.count
    chosen = set()
    for name in sorted(suites, key=lambda name: (-seconds[name], name)):
        lightest = min(range(shard.count), key=lambda index: (loads[index], index))
        loads[lightest] += seconds[name]
        if lightest + _FIRST_SHARD_NUMBER == shard.number:
            chosen.add(name)
    return frozenset(chosen)
