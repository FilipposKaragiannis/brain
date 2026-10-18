---
type: regex
target:
  source: file
  path: plugins/demo/plugin.source.json
pattern: "\\{(?=[^{}]*\"name\"\\s*:\\s*\"release-notes\")(?=[^{}]*\"invocation\"\\s*:\\s*\"user\")[^{}]*\\}"
flags: ""
match: contains
---
plugin.source.json registers release-notes with "invocation": "user".
