import { open, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import type { AgentHost, SessionRef, TranscriptTurn } from '../snapshot.ts';

/** What the locator reads of the disk. Injected so a test can hand it a home in a temp folder. */
export type SessionFiles = {
  list(folder: string): Promise<string[]>;
  modifiedMs(file: string): Promise<number | null>;
  /** The first `bytes` of a file, or null when it cannot be read. */
  head(file: string, bytes: number): Promise<string | null>;
};

export const diskSessionFiles: SessionFiles = {
  list: async (folder) => { try { return await readdir(folder); } catch { return []; } },
  modifiedMs: async (file) => { try { return (await stat(file)).mtimeMs; } catch { return null; } },
  head: async (file, bytes) => {
    try {
      const handle = await open(file, 'r');
      try {
        const buffer = Buffer.alloc(bytes);
        const { bytesRead } = await handle.read(buffer, 0, bytes, 0);
        return buffer.subarray(0, bytesRead).toString('utf8');
      } finally { await handle.close(); }
    } catch { return null; }
  },
};

export type SessionLocatorDependencies = { home: string; clock: () => Date; files: SessionFiles };

/** A process the locator looks a session up for: its host, working directory and age. */
export type SessionProcess = { host: AgentHost; cwd: string; elapsedSeconds: number };

const MILLISECONDS_PER_SECOND = 1000;
const MILLISECONDS_PER_DAY = 86400000;
/** ps rounds the elapsed time down to the second, so a file written in the process's first second still counts. */
const START_SLACK_MS = 2000;
/** How far back the Codex day folders are searched for a process that has run for days. */
const CODEX_DAYS_BACK = 14;
/** The session_meta line holds the base instructions, so it can be long; this much is read to find the cwd. */
const CODEX_HEAD_BYTES = 256 * 1024;
const TRANSCRIPT_EXTENSION = '.jsonl';
/** The ids the hosts write: a uuid. Anything else is not a session file of theirs, and never reaches a terminal. */
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/**
 * Claude keeps a folder's transcripts in `~/.claude/projects/<the folder with every character
 * that is not a letter or a digit replaced by ->`: `/work/projects/foosbrawl` is
 * `-work-projects-foosbrawl`, and a `.` in a path becomes `-` too.
 */
export function claudeProjectFolder(home: string, cwd: string): string {
  return path.join(home, '.claude', 'projects', cwd.replace(/[^A-Za-z0-9]/g, '-'));
}

/** `claude --resume <id>` or `codex resume <id>`, the argv that opens the session again. */
export function resumeCommand(host: AgentHost, id: string): string[] {
  return host === 'claude' ? ['claude', '--resume', id] : ['codex', 'resume', id];
}

/** `YYYY/MM/DD` in local time, the way Codex names its day folders. */
function dayFolder(at: Date): string {
  return `${at.getFullYear()}/${String(at.getMonth() + 1).padStart(2, '0')}/${String(at.getDate()).padStart(2, '0')}`;
}

/** The cwd and id of a Codex session file, from its first line (`session_meta`). */
export function codexMeta(head: string): { cwd: string; id: string } | null {
  const line = head.split('\n')[0] ?? '';
  try {
    const parsed = JSON.parse(line) as { type?: unknown; payload?: { cwd?: unknown; id?: unknown } };
    if (parsed.type !== 'session_meta' || typeof parsed.payload?.cwd !== 'string' || typeof parsed.payload.id !== 'string') return null;
    return { cwd: parsed.payload.cwd, id: parsed.payload.id };
  } catch {
    // A first line longer than the head: the id and cwd come before the long base instructions.
    const cwd = /"cwd":"((?:[^"\\]|\\.)*)"/.exec(line)?.[1];
    const id = /"payload":\{[^{}]*?"id":"([^"]+)"/.exec(line)?.[1];
    if (!line.includes('"session_meta"') || cwd === undefined || id === undefined) return null;
    try { return { cwd: JSON.parse(`"${cwd}"`) as string, id }; } catch { return null; }
  }
}

/**
 * Finds the transcript a claude or codex process writes, so the console can hand the owner its
 * session: a running `claude -p` cannot be attached to, but `claude --resume <id>` opens the
 * same session once it ends. The newest transcript written at or after the process started
 * wins. Codex's `session_index.jsonl` holds ids and thread names but no folder, so the session
 * files under `~/.codex/sessions/<day>/` are read instead: their first line names the cwd.
 */
export class SessionLocator {
  private readonly deps: SessionLocatorDependencies;
  /** A Codex session file's first line never changes: read once. */
  private readonly codexMetas = new Map<string, { cwd: string; id: string } | null>();

  constructor(dependencies: SessionLocatorDependencies) { this.deps = dependencies; }

  async find(process: SessionProcess): Promise<SessionRef | null> {
    const startedMs = this.deps.clock().getTime() - process.elapsedSeconds * MILLISECONDS_PER_SECOND - START_SLACK_MS;
    return process.host === 'claude' ? this.claude(process.cwd, startedMs) : this.codex(process.cwd, startedMs);
  }

  private async claude(cwd: string, startedMs: number): Promise<SessionRef | null> {
    const folder = claudeProjectFolder(this.deps.home, cwd);
    let best: { file: string; modified: number } | null = null;
    for (const name of await this.deps.files.list(folder)) {
      if (!name.endsWith(TRANSCRIPT_EXTENSION) || !SESSION_ID.test(path.basename(name, TRANSCRIPT_EXTENSION))) continue;
      const file = path.join(folder, name);
      const modified = await this.deps.files.modifiedMs(file);
      if (modified === null || modified < startedMs) continue;
      if (best === null || modified > best.modified) best = { file, modified };
    }
    if (best === null) return null;
    const id = path.basename(best.file, TRANSCRIPT_EXTENSION);
    return { host: 'claude', id, transcript: best.file, resume: resumeCommand('claude', id) };
  }

  private async codex(cwd: string, startedMs: number): Promise<SessionRef | null> {
    const root = path.join(this.deps.home, '.codex', 'sessions');
    const now = this.deps.clock().getTime();
    const from = Math.max(startedMs - MILLISECONDS_PER_DAY, now - CODEX_DAYS_BACK * MILLISECONDS_PER_DAY);
    const days = new Set<string>();
    for (let at = from; at <= now + MILLISECONDS_PER_DAY; at += MILLISECONDS_PER_DAY) days.add(dayFolder(new Date(at)));
    let best: { file: string; modified: number; id: string } | null = null;
    for (const day of days) {
      const folder = path.join(root, day);
      for (const name of await this.deps.files.list(folder)) {
        if (!name.endsWith(TRANSCRIPT_EXTENSION)) continue;
        const file = path.join(folder, name);
        const modified = await this.deps.files.modifiedMs(file);
        if (modified === null || modified < startedMs || (best !== null && modified <= best.modified)) continue;
        const meta = await this.meta(file);
        if (meta === null || !SESSION_ID.test(meta.id) || path.resolve(meta.cwd) !== path.resolve(cwd)) continue;
        best = { file, modified, id: meta.id };
      }
    }
    return best === null ? null : { host: 'codex', id: best.id, transcript: best.file, resume: resumeCommand('codex', best.id) };
  }

  private async meta(file: string): Promise<{ cwd: string; id: string } | null> {
    if (this.codexMetas.has(file)) return this.codexMetas.get(file) ?? null;
    const head = await this.deps.files.head(file, CODEX_HEAD_BYTES);
    const meta = head === null ? null : codexMeta(head);
    this.codexMetas.set(file, meta);
    return meta;
  }
}

/** A locator that finds nothing, for a monitor built without one (tests that do not look at sessions). */
export const noSessions: Pick<SessionLocator, 'find'> = { find: async () => null };

export const TRANSCRIPT_TURNS_DEFAULT = 20;
export const TRANSCRIPT_TURNS_MAX = 200;
/** A transcript can run to tens of megabytes; the last turns are in its tail. */
const TRANSCRIPT_TAIL_BYTES = 4 * 1024 * 1024;

/** The text of a message's content: the string itself, or its `text` parts joined (tool calls, tool results and thinking left out). */
function textOf(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.flatMap((part) => {
    const record = part as { type?: unknown; text?: unknown } | null;
    return record !== null && typeof record === 'object' && record.type === 'text' && typeof record.text === 'string' ? [record.text] : [];
  }).join('\n');
}

/**
 * The last `limit` turns with text in a claude transcript (`*.jsonl`, one JSON object per line):
 * user and assistant lines, their `message.content` text parts, oldest first. Meta lines (a
 * command's caveat), side chains (a subagent's own talk) and turns with no text (a tool call, a
 * tool result) are left out; a line cut by the tail or not JSON is skipped.
 */
export function parseTranscript(source: string, limit: number): TranscriptTurn[] {
  const turns: TranscriptTurn[] = [];
  for (const line of source.split('\n')) {
    if (line.trim() === '') continue;
    let entry: { type?: unknown; isMeta?: unknown; isSidechain?: unknown; timestamp?: unknown; message?: { role?: unknown; content?: unknown } };
    try { entry = JSON.parse(line) as typeof entry; } catch { continue; }
    if ((entry.type !== 'user' && entry.type !== 'assistant') || entry.isMeta === true || entry.isSidechain === true) continue;
    const text = textOf(entry.message?.content).trim();
    if (text === '') continue;
    turns.push({ at: typeof entry.timestamp === 'string' ? entry.timestamp : null, role: entry.type, text });
  }
  return turns.slice(-limit);
}

/** The tail of a transcript file, at most 4 MB, from the first whole line in it. */
export async function readTranscriptTail(file: string): Promise<string | null> {
  try {
    const handle = await open(file, 'r');
    try {
      const { size } = await handle.stat();
      const start = Math.max(0, size - TRANSCRIPT_TAIL_BYTES);
      const buffer = Buffer.alloc(size - start);
      await handle.read(buffer, 0, buffer.length, start);
      const text = buffer.toString('utf8');
      return start === 0 ? text : text.slice(text.indexOf('\n') + 1);
    } finally { await handle.close(); }
  } catch { return null; }
}
