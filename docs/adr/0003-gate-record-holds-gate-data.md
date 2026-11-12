# ADR 0003: the gate record holds the gate's data

Date: 2026-11-09. Status: accepted.

## Context
A gate was its tracker state (`gate`, `gate_from`) plus one record per item in the flow home,
`<flow home>/gates/<item>.json` (`gate item message time host`), which `notify.sh` writes and
`gate.sh list`, the board, the health job and the console read. A gate now also carries the
options the owner can pick, who raised it, who carries the answer out, the condition it waits on
and a footer with the exact command. Those need a home that every reader can reach.

## Decision
- The new fields live in the flow-home record, beside the old ones: `options` (an array of
  `{label, text, recommended}`), `raised_by`, `answered_by`, `condition` (or null) and `footer`.
  `gate.sh raise` derives them and passes them to `notify.sh` as trailing `key:=json` pairs; the
  record stays the one source.
- Tracker state keeps `gate` and `gate_from` only. No adapter's state whitelist changes.
- `gate.sh list --json` appends the fields after the old ones, with defaults for a record written
  before them (`options: []`, the rest null).
- The tracker comment and the notification carry the message, a blank line and the footer. The
  record keeps the two apart, so a reader shows the roles as data rather than a repeated
  paragraph.
- Rejected: new tracker-state keys. Three adapters and the GitHub labels would each need an array
  value, the local adapter's flat frontmatter cannot hold one, and the state and the record
  would be two sources of truth for one gate.

## Consequences
- The record is per machine: the flow home is the main worktree's `.flow`. Another host, or
  another clone, has the tracker state but no record, so it sees no options and no roles.
- The footer is the fallback there: the tracker comment names the plain `gate.sh clear` command
  (and `--option N` when the gate has options), so the owner is never stuck on another host.
- A reader of the record tolerates the new keys being absent; a record from an older plugin lists
  with the defaults.
