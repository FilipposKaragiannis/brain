import { execFile } from 'node:child_process';
import path from 'node:path';
import type { OpenWith } from './snapshot.ts';

export type { OpenWith };

/** A file `POST /api/open` may show, and whether it is a folder (a folder only shows in Finder). */
export type KnownFile = { path: string; folder: boolean };

/** Runs one program with its argv and no shell; resolves with the error text when it fails. */
export type OpenRunner = (command: string, args: string[]) => Promise<{ ok: true } | { ok: false; error: string }>;

export type OpenPlan = { ok: true; command: string; args: string[] } | { ok: false; status: number; error: string };

const HTTP_BAD_REQUEST = 400;
const HTTP_NOT_IMPLEMENTED = 501;
const OPEN_TIMEOUT_MS = 10000;
const FLAGS: Record<OpenWith, string> = { editor: '-t', finder: '-R' };

/**
 * What `POST /api/open` runs for a body `{path, with}`: `open -t <path>` (the default text editor)
 * or `open -R <path>` (the file selected in Finder), for a known file only. Anything else is a
 * 400 with the reason, and a daemon off macOS, where there is no `open`, answers 501.
 */
export function openPlan(body: unknown, known: KnownFile[], platform: NodeJS.Platform): OpenPlan {
  const record = (typeof body === 'object' && body !== null && !Array.isArray(body) ? body : {}) as { path?: unknown; with?: unknown };
  const how = record.with;
  if (how !== 'editor' && how !== 'finder') return { ok: false, status: HTTP_BAD_REQUEST, error: 'with must be editor or finder' };
  if (typeof record.path !== 'string' || !path.isAbsolute(record.path)) return { ok: false, status: HTTP_BAD_REQUEST, error: 'path must be an absolute path' };
  const asked = path.resolve(record.path);
  const file = known.find((entry) => path.resolve(entry.path) === asked);
  if (file === undefined) return { ok: false, status: HTTP_BAD_REQUEST, error: `${asked} is not a file the console opens: only its settings file, its state folder and each watched project's .flow/config.yaml` };
  if (file.folder && how === 'editor') return { ok: false, status: HTTP_BAD_REQUEST, error: `${asked} is a folder: show it in Finder` };
  if (platform !== 'darwin') return { ok: false, status: HTTP_NOT_IMPLEMENTED, error: `opening a file needs macOS (the open command); this daemon runs on ${platform}` };
  return { ok: true, command: 'open', args: [FLAGS[how], asked] };
}

/** The real runner: execFile, so no shell ever reads the path. */
export const execFileOpenRunner: OpenRunner = (command, args) => new Promise((resolve) => {
  execFile(command, args, { timeout: OPEN_TIMEOUT_MS }, (error, _stdout, stderr) => {
    if (error === null) resolve({ ok: true });
    else resolve({ ok: false, error: String(stderr).trim() || error.message });
  });
});
