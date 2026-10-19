---
type: regex
pattern: "^(?=[\\s\\S]*config\\.yaml)(?=[\\s\\S]*notify\\.sh)(?=[\\s\\S]*run-unattended\\.sh)(?=[\\s\\S]*flow\\.rules)(?=[\\s\\S]*\\.codex/)(?=[\\s\\S]*agents/)(?=[\\s\\S]*\\.gitignore)"
flags: ""
match: contains
target: last_message
---
The report names the files that changed: .flow/config.yaml, .flow/notify.sh,
.flow/run-unattended.sh, the Codex rules and agents under .codex/, and .gitignore.
