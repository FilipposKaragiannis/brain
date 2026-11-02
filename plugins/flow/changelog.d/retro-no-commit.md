bump: patch

- The retro job commits nothing: the lessons log (`.flow/lessons.jsonl`, `.flow/retros.log`)
  stays on this machine under `.flow/`, which git has ignored since init moved it to
  `.git/info/exclude`, so every run had only said it left the commit out. The `retro.commit` key
  goes, and `init --check` names a config that still sets it as unused. The config comment init
  writes and the `jobs` skill say the lessons stay on this machine.
