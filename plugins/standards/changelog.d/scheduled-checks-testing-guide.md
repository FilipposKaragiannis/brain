bump: patch

- The testing guide template's "scheduled check" row now names an entry under `jobs.checks` in
  `.flow/config.yaml`, which the flow's check job runs on its schedule from a clean checkout of the
  base, and says a CI workflow with an `on: schedule` trigger works too. Before, it said neither
  plugin runs a scheduled check.
