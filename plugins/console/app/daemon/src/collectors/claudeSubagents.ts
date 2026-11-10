import path from 'node:path';
import type { SessionRef, Subagent, TranscriptLine } from '../snapshot.ts';
import type { SessionFiles } from './sessions.ts';
import { parseTranscriptLines } from './sessions.ts';
import type { SubagentReaderDependencies } from './subagents.ts';

/** What a subagent's `agent-<id>.meta.json` says, as read at the meta's `modifiedMs`; `about` is null once it finished or was stopped. */
export type ClaudeSubagentMeta = { modifiedMs: number; about: { type: string; task: string | null } | null };

/** What a subagent transcript's first line says: the folder it works in and when it started, null where it says nothing. */
export type ClaudeSubagentStart = { cwd: string | null; startedAt: string | null };

/**
 * What the claude reader keeps between reads, by file path: each meta until its file changes,
 * each transcript's first line for the life of the file, each with when a read last used it
 * (`seenMs`). An entry no read used within the live window goes; one reader serves every
 * project, so an entry that only another project's read uses is kept.
 */
export type ClaudeSubagentCache = {
  metas: Map<string, ClaudeSubagentMeta & { seenMs: number }>;
  starts: Map<string, ClaudeSubagentStart & { seenMs: number }>;
};

/**
 * A subagent counts as live while its transcript was written this recently. A meta without
 * `finished` is no proof: a crashed or stopped session leaves those behind for days.
 */
export const LIVE_WINDOW_MS = 10 * 60000;
/** A meta file is a few hundred bytes; this much is read of it. */
const META_BYTES = 64 * 1024;
/** A transcript's first line carries the whole prompt ahead of its cwd and timestamp; this much is read to find them. */
const START_BYTES = 256 * 1024;
/** How much of a transcript's end is read for its latest line. */
const TAIL_BYTES = 64 * 1024;
const SUBAGENTS_FOLDER = 'subagents';
/** A subagent's meta file in a session's `subagents/` folder; its `workflows/` folder and anything else is not one. */
const META_FILE = /^agent-([0-9a-f]+)\.meta\.json$/;
/** The type a subagent shows when its meta names no `agentType`. */
const UNTYPED = 'subagent';
const NO_START: ClaudeSubagentStart = { cwd: null, startedAt: null };

/** What one read works with: the disk, the reader's cache and the time it reads at. */
type Reading = { files: SessionFiles; cache: ClaudeSubagentCache; now: number };

/** An empty cache, one per reader. */
export function claudeSubagentCache(): ClaudeSubagentCache {
  return { metas: new Map(), starts: new Map() };
}

/**
 * The live subagents of each claude session, in the same order as `sessions`, each list oldest
 * first: those in `<transcript folder>/<session id>/subagents/` whose transcript was written within
 * `LIVE_WINDOW_MS` and whose meta says neither `finished` nor `stoppedByUser`. Reads through
 * `cache` and updates it.
 */
export async function claudeSubagents(sessions: readonly SessionRef[], dependencies: SubagentReaderDependencies, cache: ClaudeSubagentCache): Promise<Subagent[][]> {
  const reading: Reading = { files: dependencies.files, cache, now: dependencies.clock().getTime() };
  forgetUnused(reading);
  const rows: Subagent[][] = [];
  for (const session of sessions) rows.push(await sessionSubagents(session, reading));
  return rows;
}

/** Drops the cache entries no read used within the live window. */
function forgetUnused({ cache, now }: Reading): void {
  const oldest = now - LIVE_WINDOW_MS;
  for (const [file, entry] of [...cache.metas]) if (entry.seenMs < oldest) cache.metas.delete(file);
  for (const [file, entry] of [...cache.starts]) if (entry.seenMs < oldest) cache.starts.delete(file);
}

async function sessionSubagents(session: SessionRef, reading: Reading): Promise<Subagent[]> {
  const folder = path.join(path.dirname(session.transcript), session.id, SUBAGENTS_FOLDER);
  const found: Subagent[] = [];
  for (const name of await reading.files.list(folder)) {
    const id = META_FILE.exec(name)?.[1];
    const subagent = id === undefined ? null : await liveSubagent(folder, id, reading);
    if (subagent !== null) found.push(subagent);
  }
  return found.sort(byStart);
}

/** The subagent `id` of a `subagents/` folder, or null when its transcript went quiet or its meta says it ended. */
async function liveSubagent(folder: string, id: string, reading: Reading): Promise<Subagent | null> {
  const transcript = path.join(folder, `agent-${id}.jsonl`);
  const written = await reading.files.modifiedMs(transcript);
  if (written === null || reading.now - written > LIVE_WINDOW_MS) return null;
  const about = await cachedMeta(path.join(folder, `agent-${id}.meta.json`), reading);
  if (about === null) return null;
  const { cwd, startedAt } = await cachedStart(transcript, reading);
  return { id, host: 'claude', type: about.type, task: about.task, cwd, startedAt, latest: await latestLine(transcript, reading.files) };
}

/** A meta's `about`, from the cache while the file is unchanged, else read and cached. */
async function cachedMeta(file: string, { files, cache, now }: Reading): Promise<ClaudeSubagentMeta['about']> {
  const modifiedMs = await files.modifiedMs(file);
  if (modifiedMs === null) return null;
  const kept = cache.metas.get(file);
  if (kept !== undefined && kept.modifiedMs === modifiedMs) { kept.seenMs = now; return kept.about; }
  const text = await files.head(file, META_BYTES);
  const about = text === null ? null : metaAbout(text);
  cache.metas.set(file, { modifiedMs, about, seenMs: now });
  return about;
}

/** The type and task a meta names, or null for one that finished, was stopped or is not a JSON object. */
function metaAbout(text: string): ClaudeSubagentMeta['about'] {
  const meta = jsonObject(text);
  if (meta === null || meta['finished'] === true || meta['stoppedByUser'] === true) return null;
  return { type: nonEmpty(meta['agentType']) ?? UNTYPED, task: nonEmpty(meta['description']) };
}

/** A transcript's start, from the cache, else read from its first line and cached for the life of the file. */
async function cachedStart(file: string, { files, cache, now }: Reading): Promise<ClaudeSubagentStart> {
  const kept = cache.starts.get(file);
  if (kept !== undefined) { kept.seenMs = now; return kept; }
  const head = await files.head(file, START_BYTES);
  if (head === null || head === '') return NO_START;
  const first = jsonObject(head.split('\n', 1)[0] ?? '');
  const start = first === null ? NO_START : { cwd: nonEmpty(first['cwd']), startedAt: nonEmpty(first['timestamp']) };
  cache.starts.set(file, { ...start, seenMs: now });
  return start;
}

/** The last line a subagent's transcript tail makes (every line of it is a side chain), or null when it makes none. */
async function latestLine(file: string, files: SessionFiles): Promise<TranscriptLine | null> {
  const tail = await files.tail(file, TAIL_BYTES);
  return tail === null ? null : parseTranscriptLines(tail, { sidechains: true }).at(-1) ?? null;
}

/** The JSON object a text holds, or null when it holds anything else or no JSON at all. */
function jsonObject(text: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(text);
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
  } catch { return null; }
}

/** A non-empty string, else null. */
function nonEmpty(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null;
}

/** Oldest start first; a subagent with no start goes last, ties by id. */
function byStart(left: Subagent, right: Subagent): number {
  if (left.startedAt === right.startedAt) return left.id < right.id ? -1 : 1;
  if (left.startedAt === null) return 1;
  if (right.startedAt === null) return -1;
  return left.startedAt < right.startedAt ? -1 : 1;
}
