bump: minor

- The health job says when a step got slower. Each pass asks the graph report which steps its
  verdict names as slower (`graph-report.sh --slower`, new: a line per step with its median now
  and before, apart by tabs, and no history kept) and says and notifies each once, with both
  medians over the last 7 days and the 7 before. A step that stays slower is not said again; one
  that recovers is forgotten, so its next slowdown is said anew. `--dry-run` says it and records
  nothing.
- A graph report that fails is one health finding, said once per error, and the pass goes on. No
  model runs.
