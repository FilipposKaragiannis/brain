bump: patch

- SH-11 no longer asks for a contract line above each function. A script's header says what the
  script is for and what it takes; no comment above or inside a function says what the code does,
  names carry the meaning, and a comment stays only for a why the code cannot show.
- At project scope the block init installs names only the appendix files it installs for the
  configured languages, in the plugin's order, and no language sentence when none has an appendix.
  It used to name every appendix, so a shell project's block pointed at a `csharp.md` it did not
  have. The machine-scope block still names every appendix, as every one installs there.
