---
paths:
  - "**/*.sh"
---
# Appendix B. Shell

Files: `.sh`.

- **SH-01** Target POSIX `sh`. No bash features.
- **SH-02** Start with `set -u`. Check every command whose failure matters. Never report success after a failed step.
- **SH-03** Quote every expansion. Pass a list as `"$@"` or read it line by line, never by word splitting.
- **SH-04** Data never becomes code. No `eval`, and no `sh -c` on a string that holds data. Pass data as arguments, with `--` before file names.
- **SH-05** No new parsing of JSON, YAML or shell syntax with `sed`, `awk` or `grep`. One Python or `jq` call reads structured data.
- **SH-06** Resolve a value once per script and pass it on. Never start a process per item in a loop.
- **SH-07** A function assigns only names that carry its prefix. It returns through stdout or its exit status.
- **SH-08** Write state files through a temp file and `mv`.
- **SH-09** Temp files come from `mktemp`, and a `trap` removes them.
- **SH-10** A script over 300 lines, or one that needs data structures, moves its logic to Python.
- **SH-11** A script's header says what the script is for and what it takes. No comment above or inside a function says what the code does: names carry the meaning. A comment stays only for a why the code cannot show.
- **SH-12** One sandboxed test file per area that runs alone. One behaviour per check, named `Scenario_Outcome`. Waits poll with a bound.
- **SH-13** ShellCheck is clean on new and touched lines. A `disable` note gives its reason.
