bump: minor

- The rule generator turns every `## Appendix <letter>. <Language>` section of the coding
  standards into its own rule file, indexes its ids as conventions and lists each appendix with
  the file types its `Files:` line names in `rules/appendices.json`. The compact block names every
  appendix.
- Two new appendices: B. Shell (SH-01 to SH-13) and C. Python (PY-01 to PY-18). PY-02, PY-06,
  PY-07 and PY-10 carry the suggested readings of the type checker, S-13, D-09 and pytest, which
  the owner has still to confirm.
- `init` installs a language appendix only when a configured language shares a file extension
  with it, and its Claude rule loads for that language's files alone, so a `.sh` read no longer
  loads the C# appendix. An appendix the project stops using is removed when init wrote it. At
  machine scope every appendix installs, each for its own extensions. The drift hash covers every
  appendix and the appendix list.
