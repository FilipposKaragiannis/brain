# ADR 0004: config migrations are steps that look only at the file

Date: 2026-11-26. Status: accepted.

## Context
Flow and standards changed settings without updating a project's config: a plugin read the old
key as a fallback and warned, or init printed a note asking the owner to edit by hand. A
migration keyed on plugin versions cannot work. A PR does not know its release version (ADR
0002), and no existing config records a version that is true: nothing records which flow version
wrote `.flow/config.yaml`, and the standards `version` is the one that created the file.

## Decision
- Each plugin ships one ordered list of steps (`skills/init/migrations.json`). A step looks only
  at the file: a `remove` acts when its key is there, an `add` when its key is not, a `move` when
  the old key is there. Init runs the list before it copies anything.
- The version in the config (`config_version` in flow, `version` in standards) is a label. Init
  writes its own manifest version there when it changes the file, and uses the label it found to
  name the backup. It is never compared.
- The flow helper edits whole lines of the flat YAML subset and never writes the file again from
  a parsed form. It refuses a file outside the subset whole, and reads its own result again
  before it writes.
- Rejected: steps tagged with a version (a PR would write a placeholder for the release to fill);
  a count of applied steps (the backup still needs a version, so a second record); the console's
  TypeScript editor (init would need Node); `yq` or `ruamel.yaml` (not on the machine or in CI);
  parsing and writing the YAML again (every comment lost).

## Consequences
- Pending steps come from a dry run of the same code, so `init --check`, a second run and a
  project that skipped releases all behave correctly without knowing a version.
- An `add` step writes back a default the owner deleted, on the next init.
- Every existing flow config is migrated once for its missing label, and its first backup is
  named `unversioned`.
