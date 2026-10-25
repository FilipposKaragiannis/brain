import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';

/** What a daemon started in the foreground leaves in <state dir>/daemon.pid while it runs. */
export type PidRecord = { pid: number; port: number; config: string; argv: string[] };

const PID_FILE_MODE = 0o600;

export function pidFilePath(stateDir: string): string {
  return path.join(stateDir, 'daemon.pid');
}

/** The record in the file's text, or null when it is not one (a hand edit, a half write). */
export function parsePidRecord(text: string): PidRecord | null {
  try {
    const value = JSON.parse(text) as Partial<PidRecord>;
    if (!Number.isInteger(value.pid) || !Number.isInteger(value.port) || typeof value.config !== 'string' || !Array.isArray(value.argv)) return null;
    return { pid: value.pid as number, port: value.port as number, config: value.config, argv: value.argv.filter((word): word is string => typeof word === 'string') };
  } catch { return null; }
}

/** Written whole through a temp file, so `status` never reads half of it. */
export function writePidFile(stateDir: string, record: PidRecord): void {
  const file = pidFilePath(stateDir);
  const temporary = `${file}.${process.pid}.tmp`;
  writeFileSync(temporary, JSON.stringify(record) + '\n', { mode: PID_FILE_MODE });
  renameSync(temporary, file);
}

/** Removes the file only while it still names this pid: a newer daemon's file is left alone. */
export function removePidFile(stateDir: string, pid: number): void {
  const file = pidFilePath(stateDir);
  try {
    if (parsePidRecord(readFileSync(file, 'utf8'))?.pid === pid) rmSync(file, { force: true });
  } catch { /* no file: nothing to remove */ }
}
