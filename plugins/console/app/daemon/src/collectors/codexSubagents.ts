import path from 'node:path';
import type { SessionRef, Subagent, TranscriptLine } from '../snapshot.ts';
import { parseCodexTranscript } from './codexTranscript.ts';
import type { CodexMeta, SessionFiles } from './sessions.ts';
import { codexDayFolders, readCodexMeta } from './sessions.ts';
import type { SubagentReaderDependencies } from './subagents.ts';

/** What the codex reader keeps between reads, by rollout path: each first line, which never changes. Entries for files a read did not ask about go. */
export type CodexSubagentCache = { metas: Map<string, CodexMeta> };

/** An empty cache, one per reader. */
export function codexSubagentCache(): CodexSubagentCache {
  return { metas: new Map() };
}

/** A child rollout not written for this long is not at work, whatever its last turn says. */
const LIVE_WINDOW_MS = 10 * 60000;
/** How much of a child rollout is read for its last turn event and its latest line. */
const CHILD_TAIL_BYTES = 64 * 1024;
const ROLLOUT_EXTENSION = '.jsonl';
/** The type a child spawned without a role shows. */
const UNNAMED_ROLE = 'subagent';
const TASK_STARTED = 'task_started';
const TASK_COMPLETE = 'task_complete';
/** The cheap substring test that skips parsing the lines that are no turn event. */
const TURN_EVENT_MARK = '"task_';
/** Where a row without a start sorts: after every row with one. */
const UNKNOWN_START = Number.MAX_SAFE_INTEGER;

/** A child rollout of one of the sessions read, with its first line. */
type Child = { file: string; meta: CodexMeta };
/** The fresh children a scan found, and every rollout whose first line it asked about. */
type Scan = { children: Child[]; asked: Set<string> };
/** A rollout line as far as the reader looks into it. */
type RolloutEntry = { type?: unknown; ordinal?: unknown; payload?: { type?: unknown } };

/**
 * The live subagents of each codex session, at every depth, in the same order as `sessions`,
 * oldest started first. A child is its own rollout in Codex's day folders, run by its root's
 * process: its first line names the root session (`session_id`), so the folders are scanned from
 * the earliest start of the sessions read to today for rollouts written in the last 10 minutes
 * whose first line is a subagent of one of them. One is live while its last turn has not
 * completed. The first lines read are kept for as long as each read asks about them.
 */
export async function codexSubagents(sessions: readonly SessionRef[], dependencies: SubagentReaderDependencies, cache: CodexSubagentCache): Promise<Subagent[][]> {
  const { children, asked } = sessions.length === 0 ? { children: [], asked: new Set<string>() } : await scanFreshChildren(sessions, dependencies, cache);
  forgetUnasked(cache, asked);
  const rows = new Map<string, Subagent[]>();
  for (const child of children) {
    const row = await liveRow(child, dependencies.files);
    if (row !== null) rows.set(child.meta.rootId, [...(rows.get(child.meta.rootId) ?? []), row]);
  }
  return sessions.map((session) => (rows.get(session.id) ?? []).toSorted((left, right) => startKey(left) - startKey(right)));
}

/** The children of the sessions read whose rollouts were written within the live window, from the earliest start of those sessions on. */
async function scanFreshChildren(sessions: readonly SessionRef[], dependencies: SubagentReaderDependencies, cache: CodexSubagentCache): Promise<Scan> {
  const now = dependencies.clock().getTime();
  const roots = new Set(sessions.map((session) => session.id));
  const asked = new Set<string>();
  let since = now;
  for (const session of sessions) {
    asked.add(session.transcript);
    since = Math.min(since, (await cachedMeta(session.transcript, dependencies.files, cache))?.startedMs ?? 0);
  }
  const children: Child[] = [];
  for (const folder of codexDayFolders(dependencies.home, since, now)) {
    for (const name of await dependencies.files.list(folder)) {
      const file = path.join(folder, name);
      const modified = name.endsWith(ROLLOUT_EXTENSION) ? await dependencies.files.modifiedMs(file) : null;
      if (modified === null || now - modified > LIVE_WINDOW_MS) continue;
      asked.add(file);
      const meta = await cachedMeta(file, dependencies.files, cache);
      if (meta !== null && meta.subagent && meta.id !== meta.rootId && roots.has(meta.rootId)) children.push({ file, meta });
    }
  }
  return { children, asked };
}

/** A rollout's first line from the cache, read and kept there on its first ask; one that cannot be read yet is asked again next time. */
async function cachedMeta(file: string, files: SessionFiles, cache: CodexSubagentCache): Promise<CodexMeta | null> {
  const kept = cache.metas.get(file);
  if (kept !== undefined) return kept;
  const meta = await readCodexMeta(files, file);
  if (meta !== null) cache.metas.set(file, meta);
  return meta;
}

/** Forgets the first lines of the rollouts a read did not ask about, so the cache holds only the live ones. */
function forgetUnasked(cache: CodexSubagentCache, asked: ReadonlySet<string>): void {
  for (const file of [...cache.metas.keys()]) if (!asked.has(file)) cache.metas.delete(file);
}

/** A child's row while it is at work, or null once its last turn completed or its rollout cannot be read. */
async function liveRow(child: Child, files: SessionFiles): Promise<Subagent | null> {
  const tail = await files.tail(child.file, CHILD_TAIL_BYTES);
  if (tail === null || !isAtWork(tail)) return null;
  const { meta } = child;
  return {
    id: meta.id, host: 'codex', type: meta.agentRole ?? UNNAMED_ROLE, task: taskOf(meta), cwd: meta.cwd,
    startedAt: meta.startedMs === null ? null : new Date(meta.startedMs).toISOString(), latest: latestOwnLine(tail, meta.historyStart),
  };
}

/** Whether the last turn event in a tail is not a `task_complete`: a tail with none is in the middle of a long turn. */
function isAtWork(tail: string): boolean {
  let last: string | null = null;
  for (const raw of tail.split('\n')) {
    const event = raw.includes(TURN_EVENT_MARK) ? turnEvent(raw) : null;
    if (event !== null) last = event;
  }
  return last !== TASK_COMPLETE;
}

/** `task_started` or `task_complete` for a line that is that event, else null. */
function turnEvent(raw: string): string | null {
  const entry = parsedEntry(raw);
  const type = entry?.type === 'event_msg' ? entry.payload?.type : undefined;
  return type === TASK_STARTED || type === TASK_COMPLETE ? type : null;
}

/** A rollout line parsed, or null when it is cut or not JSON. */
function parsedEntry(raw: string): RolloutEntry | null {
  try {
    const entry = JSON.parse(raw) as unknown;
    return entry !== null && typeof entry === 'object' ? entry as RolloutEntry : null;
  } catch { return null; }
}

/**
 * The last line of the child's own work in a tail: the lines before its `historyStart` ordinal
 * replay its parent's, so they make none; a line without an ordinal counts as its own.
 */
function latestOwnLine(tail: string, historyStart: number | null): TranscriptLine | null {
  const own = historyStart === null ? tail : tail.split('\n').filter((raw) => !isReplayed(raw, historyStart)).join('\n');
  return parseCodexTranscript(own).lines.at(-1) ?? null;
}

/** Whether a line's ordinal comes before the child's own history. */
function isReplayed(raw: string, historyStart: number): boolean {
  const ordinal = parsedEntry(raw)?.ordinal;
  return typeof ordinal === 'number' && ordinal < historyStart;
}

/** The child's task name, the last segment of its path (`/root/probe` is `probe`), with its nickname in parentheses when it has one; null without a path. */
function taskOf(meta: CodexMeta): string | null {
  const name = meta.agentPath?.split('/').filter((segment) => segment !== '').at(-1) ?? null;
  if (name === null) return null;
  return meta.agentNickname === null ? name : `${name} (${meta.agentNickname})`;
}

/** What a row sorts by: when it started, a row without a start last. */
function startKey(row: Subagent): number {
  return row.startedAt === null ? UNKNOWN_START : Date.parse(row.startedAt);
}
