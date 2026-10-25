/**
 * The model and effort each jobs host falls back to on this machine when `.flow/config.yaml`
 * leaves `jobs.<host>.model` or `.effort` empty. Codex keeps them in `~/.codex/config.toml`;
 * Claude has no file the console can read them from reliably, so it gets none.
 */
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { HostDefaults } from './schema.ts';

/** A top-level `key = "value"` line, with an optional comment after it. */
const LINE = /^([A-Za-z0-9_-]+)\s*=\s*"([^"\\]*)"\s*(#.*)?$/;
const TABLE = /^\[/;

/**
 * `model` and `model_reasoning_effort` from the text of a codex `config.toml`: only plain
 * `key = "value"` lines before the first table (`[profiles.x]` and the like set other things),
 * anything else is skipped rather than guessed at.
 */
export function codexDefaults(text: string): { model: string | null; effort: string | null } {
  const found: Record<string, string> = {};
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (TABLE.test(line)) break;
    const match = LINE.exec(line);
    if (match !== null && found[match[1]!] === undefined) found[match[1]!] = match[2]!;
  }
  const value = (key: string): string | null => (found[key] === undefined || found[key] === '' ? null : found[key]!);
  return { model: value('model'), effort: value('model_reasoning_effort') };
}

/** The hosts' defaults read from the home folder given; codex is null when it has no config file. */
export async function readHostDefaults(home: string): Promise<HostDefaults> {
  let text: string;
  try { text = await readFile(path.join(home, '.codex', 'config.toml'), 'utf8'); } catch { return { codex: null }; }
  return { codex: codexDefaults(text) };
}
