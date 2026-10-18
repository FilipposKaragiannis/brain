---
type: regex
pattern: "the hooks and the verifier need these|^\\s*Next:\\s*$|(?:\\.standards/rules/[\\w-]+\\.md[\\s\\S]*?){5}"
flags: "m"
match: not_contains
target: last_message
---
The report does not paste the installer's output: no "Gaps (the hooks and the verifier need
these ...)" or "Next:" header from init.sh, and no per-file list of the rule copies.
