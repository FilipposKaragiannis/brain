---
type: regex
pattern: "(?:two|2|second) (?:real |justified |concrete )?adapters|adapters? (?:fill|justif|earn)|hypothetical seam|(?:seam|port) is (?:real|justified|earned)|real seam|remote but owned"
flags: "i"
match: contains
target: last_message
---
The answer applies codebase-design's seam discipline, not just the word "adapter": the port for
the remote rate service is justified by its two adapters (one adapter is a hypothetical seam, two
make a real one), or the dependency is classed as remote but owned. Plain advice also says "port"
and "adapter", so those words alone no longer pass.
