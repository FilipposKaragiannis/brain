bump: minor

- The rule generator turns every `## Appendix <letter>. <Language>` section of the coding
  standards into its own rule file, indexes its ids as conventions and lists each appendix with
  the file types its `Files:` line names in `rules/appendices.json`. The compact block names every
  appendix.
- Two new appendices: B. Shell (SH-01 to SH-13) and C. Python (PY-01 to PY-18). PY-02, PY-06,
  PY-07 and PY-10 carry the suggested readings of the type checker, S-13, D-09 and pytest, which
  the owner has still to confirm.
