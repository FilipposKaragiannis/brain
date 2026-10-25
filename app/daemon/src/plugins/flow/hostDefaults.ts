/**
 * The model and effort each jobs host falls back to on this machine when `.flow/config.yaml`
 * leaves `jobs.<host>.model` or `.effort` empty. Codex keeps them in `~/.codex/config.toml`;
 * Claude has no file the console can read them from reliably, so it gets none.
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { HostDefaults } from './schema.ts';

/** A `key = "value"` or `key = 'value'` line, with an optional comment after it. */
const LINE = /^([A-Za-z0-9_-]+)\s*=\s*(?:"([^"\\]*)"|'([^']*)')\s*(#.*)?$/;
/** A table header, `[name]` or `[a.b]` with bare or quoted parts. */
const TABLE = /^\[([^[\]]+)\]\s*(#.*)?$/;

/** A table's dotted name with its quotes taken off each part: `profiles."fast"` is `profiles.fast`. */
function tableName(header: string): string {
  return header.split('.').map((part) => part.trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1')).join('.');
}

/** Every plain string line of the file, by table (`''` for the top level); the first of a key set twice wins. */
function stringsByTable(text: string): Map<string, Record<string, string>> {
  const tables = new Map<string, Record<string, string>>([['', {}]]);
  let table: string | null = '';
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.startsWith('[')) {
      const header = TABLE.exec(line);
      // An array of tables (`[[x]]`) or a header the reader does not follow: nothing under it counts.
      table = header === null ? null : tableName(header[1]!);
      if (table !== null && !tables.has(table)) tables.set(table, {});
      continue;
    }
    if (table === null) continue;
    const match = LINE.exec(line);
    const found = tables.get(table)!;
    if (match !== null && found[match[1]!] === undefined) found[match[1]!] = match[2] ?? match[3]!;
  }
  return tables;
}

/**
 * `model` and `model_reasoning_effort` from the text of a codex `config.toml`, as codex picks
 * them: from `[profiles.<profile>]` when a top-level `profile` names one, else from the top level.
 * Only `key = "value"` and `key = 'value'` lines are read; anything else is skipped rather than
 * guessed at.
 */
export function codexDefaults(text: string): { model: string | null; effort: string | null; profile: string | null } {
  const tables = stringsByTable(text);
  const top = tables.get('')!;
  const profile = top['profile'] === undefined || top['profile'] === '' ? null : top['profile'];
  const chosen = profile === null ? {} : tables.get(`profiles.${profile}`) ?? {};
  const value = (key: string): string | null => {
    const found = chosen[key] ?? top[key];
    return found === undefined || found === '' ? null : found;
  };
  return { model: value('model'), effort: value('model_reasoning_effort'), profile };
}

/** The hosts' defaults read from the home folder given; codex is null when it has no config file. */
export async function readHostDefaults(home: string): Promise<HostDefaults> {
  let text: string;
  try { text = await readFile(path.join(home, '.codex', 'config.toml'), 'utf8'); } catch { return { codex: null }; }
  return { codex: codexDefaults(text) };
}
