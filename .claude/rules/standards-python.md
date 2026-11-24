---
paths:
  - "**/*.py"
---
# Appendix C. Python

Files: `.py`.

- **PY-01** PEP 8. Ruff formats, sorts imports and lints.
- **PY-02** Type annotations on every function signature. A type checker in lint, with a recorded baseline, is planned and does not run yet.
- **PY-03** Records are frozen dataclasses or named tuples. A function does not mutate its arguments.
- **PY-04** Outside data is parsed at the boundary into a dataclass. Inside, code uses the typed value, not a raw dict.
- **PY-05** Resources use `with`. Large or lazy sequences use generators.
- **PY-06** Catch the specific library exception where it is raised and turn it into a value or a clear exit. Own code does not raise for an expected outcome (S-13), and builds no exception class trees (D-03). No bare `except`, no handler that only passes. Chain with `from`.
- **PY-07** No default value on a function parameter (D-09). A field of a wire or config record may default where its key can be absent, never to a mutable value. Compare to `None` with `is`. Use `isinstance`. No `import *`.
- **PY-08** Secrets come from the environment, never from source. A missing one stops the script at start.
- **PY-09** Security lint runs in the build.
- **PY-10** Tests use pytest, a test-only tool installed in CI, marked unit or integration.
- **PY-11** A `Protocol` states an interface, only where a second implementation or a test seam needs one.
- **PY-12** A function returns its value. Only `main` prints. Diagnostics go to stderr.
- **PY-13** Target Python 3.9, standard library only at run time.
- **PY-14** Run as `python3 -I`, with `main()` behind the `__main__` guard.
- **PY-15** One process handles the whole batch. Shell never starts it once per item.
- **PY-16** Write state through a temp file and `os.replace`.
- **PY-17** A subprocess gets an argument list and a timeout.
- **PY-18** Time and randomness come in as arguments.
