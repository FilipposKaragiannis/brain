import { createReadStream } from 'node:fs';
import { open, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import type { AgentHost, SessionRef, TranscriptLine, TranscriptTurn } from '../snapshot.ts';
import { TRANSCRIPT_LINE_CHARS } from '../snapshot.ts';

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

/** A process the locator looks a session up for: its pid, host, working directory and age. */
export type SessionProcess = { pid: number; host: AgentHost; cwd: string; elapsedSeconds: number };

/** A waiting gate the locator looks the raising session up for: its item, when it was raised, its host (`claude`, `codex`) and the folder its step ran in. */
export type GateLookup = { item: string; raisedAt: string; host: string; cwd: string };

const MILLISECONDS_PER_SECOND = 1000;
const MILLISECONDS_PER_DAY = 86400000;
/** ps rounds the elapsed time down to the second, so a file written in the process's first second still counts. */
const START_SLACK_MS = 2000;
/** A sessions file whose procStart is further than this from the process's start belongs to an earlier process with the same pid. */
const SAME_PROCESS_MS = 10000;
/** A process whose transcript the folder scan did not find is scanned again after this, not on every read. */
const RESCAN_MS = 60000;
/** How far back the Codex day folders are searched for a process that has run for days, and how long a read session file is remembered. */
const CODEX_DAYS_BACK = 14;
/** The session_meta line holds the base instructions, so it can be long; this much is read to find the cwd. */
const CODEX_HEAD_BYTES = 256 * 1024;
const SESSIONS_FILE_BYTES = 64 * 1024;
/** A step writes its transcript up to the moment it raises its gate, so the gate's session was written no earlier than this before. */
const GATE_SLACK_MS = 30 * 60000;
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

/** `~/.claude/sessions/<pid>.json` as claude writes it for every running process. */
export function claudeSessionsFile(text: string): { pid: number; sessionId: string; cwd: string; procStart: string | null } | null {
  try {
    const parsed = JSON.parse(text) as { pid?: unknown; sessionId?: unknown; cwd?: unknown; procStart?: unknown };
    if (typeof parsed.pid !== 'number' || typeof parsed.sessionId !== 'string' || typeof parsed.cwd !== 'string') return null;
    return { pid: parsed.pid, sessionId: parsed.sessionId, cwd: parsed.cwd, procStart: typeof parsed.procStart === 'string' ? parsed.procStart : null };
  } catch { return null; }
}

type Found = { session: SessionRef | null; certain: boolean };
type GateScan = { session: SessionRef | null; scannedAt: number };
type Remembered = { startedMs: number; session: SessionRef | null; scannedAt: number };

/**
 * Finds the session a claude or codex process writes, so the console can hand the owner its
 * session: a running `claude -p` cannot be attached to, but `claude --resume <id>` opens the
 * same session once it ends.
 *
 * Claude writes `~/.claude/sessions/<pid>.json` (its sessionId, cwd and procStart) for every
 * running process, so that answers first, checked against the process's folder and start. Only
 * without it does the locator fall back to file times: the newest transcript in the folder
 * written at or after the process started. Codex's `session_index.jsonl` holds ids and thread
 * names but no folder, so its session files under `~/.codex/sessions/<day>/` are read instead:
 * their first line names the cwd. A transcript never goes to two pids: the sessions file wins,
 * then the first process listed; another claimant gets null. A scan's answer is kept for the
 * life of the process (a miss is tried again a minute later), so a read costs one small file per
 * claude process.
 */
export class SessionLocator {
  private readonly deps: SessionLocatorDependencies;
  /** A Codex session file's first line never changes: read once, forgotten after 14 days. */
  private readonly codexMetas = new Map<string, { meta: { cwd: string; id: string } | null; modified: number }>();
  /** What the folder scan found per pid, for the life of that process. */
  private readonly scanned = new Map<number, Remembered>();
  /** What the folder scan found per waiting gate (item, raise time, host and folder), for as long as the gate waits. */
  private readonly gateScans = new Map<string, GateScan>();

  constructor(dependencies: SessionLocatorDependencies) { this.deps = dependencies; }

  /** The session of each process, in the same order; null where none was found or another process holds it. */
  async assign(processes: SessionProcess[]): Promise<(SessionRef | null)[]> {
    const now = this.deps.clock().getTime();
    this.forget(processes, now);
    const found: Found[] = [];
    for (const process of processes) found.push(await this.find(process, now));
    const claimed = new Set(found.flatMap((entry) => (entry.certain && entry.session !== null ? [entry.session.transcript] : [])));
    return found.map((entry) => {
      if (entry.session === null || entry.certain) return entry.session;
      if (claimed.has(entry.session.transcript)) return null;
      claimed.add(entry.session.transcript);
      return entry.session;
    });
  }

  /**
   * The session that raised each waiting gate, in the same order; null where none was found. The
   * step that raised it has ended, so no pid or sessions file is left: the answer is the newest
   * transcript in the gate's folder written at or after 30 minutes before the raise (a discussion
   * resumed since appends to that same file). A gate's answer is kept while the gate waits (a miss
   * is tried again a minute later), and forgotten once it is no longer asked for.
   */
  async gates(gates: GateLookup[]): Promise<(SessionRef | null)[]> {
    const now = this.deps.clock().getTime();
    const keys = gates.map((gate) => JSON.stringify([gate.item, gate.raisedAt, gate.host, path.resolve(gate.cwd)]));
    const asked = new Set(keys);
    for (const key of [...this.gateScans.keys()]) if (!asked.has(key)) this.gateScans.delete(key);
    const found: (SessionRef | null)[] = [];
    for (const [index, gate] of gates.entries()) {
      const key = keys[index]!;
      const remembered = this.gateScans.get(key);
      if (remembered !== undefined && (remembered.session !== null || now - remembered.scannedAt < RESCAN_MS)) { found.push(remembered.session); continue; }
      const raised = Date.parse(gate.raisedAt);
      let session: SessionRef | null = null;
      if (!Number.isNaN(raised) && gate.host === 'claude') session = await this.claudeScan(gate.cwd, raised - GATE_SLACK_MS);
      if (!Number.isNaN(raised) && gate.host === 'codex') session = await this.codexScan(gate.cwd, raised - GATE_SLACK_MS, now);
      this.gateScans.set(key, { session, scannedAt: now });
      found.push(session);
    }
    return found;
  }

  private forget(processes: SessionProcess[], now: number): void {
    const live = new Set(processes.map((process) => process.pid));
    for (const pid of [...this.scanned.keys()]) if (!live.has(pid)) this.scanned.delete(pid);
    const oldest = now - CODEX_DAYS_BACK * MILLISECONDS_PER_DAY;
    for (const [file, entry] of [...this.codexMetas]) if (entry.modified < oldest) this.codexMetas.delete(file);
  }

  private async find(process: SessionProcess, now: number): Promise<Found> {
    const startedMs = now - process.elapsedSeconds * MILLISECONDS_PER_SECOND - START_SLACK_MS;
    if (process.host === 'claude') {
      const fromFile = await this.claudeFromSessionsFile(process, startedMs);
      if (fromFile !== null) return { session: fromFile, certain: true };
    }
    const remembered = this.scanned.get(process.pid);
    const same = remembered !== undefined && Math.abs(remembered.startedMs - startedMs) <= SAME_PROCESS_MS;
    if (same && (remembered.session !== null || now - remembered.scannedAt < RESCAN_MS)) return { session: remembered.session, certain: false };
    const session = process.host === 'claude' ? await this.claudeScan(process.cwd, startedMs) : await this.codexScan(process.cwd, startedMs, now);
    this.scanned.set(process.pid, { startedMs, session, scannedAt: now });
    return { session, certain: false };
  }

  private async claudeFromSessionsFile(process: SessionProcess, startedMs: number): Promise<SessionRef | null> {
    const text = await this.deps.files.head(path.join(this.deps.home, '.claude', 'sessions', `${process.pid}.json`), SESSIONS_FILE_BYTES);
    const entry = text === null ? null : claudeSessionsFile(text);
    if (entry === null || entry.pid !== process.pid || !SESSION_ID.test(entry.sessionId) || path.resolve(entry.cwd) !== path.resolve(process.cwd)) return null;
    // A file left by an earlier process that had the same pid starts somewhere else.
    const started = entry.procStart === null ? Number.NaN : Date.parse(entry.procStart);
    if (!Number.isNaN(started) && Math.abs(started - (startedMs + START_SLACK_MS)) > SAME_PROCESS_MS) return null;
    const transcript = path.join(claudeProjectFolder(this.deps.home, process.cwd), `${entry.sessionId}${TRANSCRIPT_EXTENSION}`);
    return { host: 'claude', id: entry.sessionId, transcript, resume: resumeCommand('claude', entry.sessionId) };
  }

  private async claudeScan(cwd: string, startedMs: number): Promise<SessionRef | null> {
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

  private async codexScan(cwd: string, startedMs: number, now: number): Promise<SessionRef | null> {
    const root = path.join(this.deps.home, '.codex', 'sessions');
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
        const meta = await this.meta(file, modified);
        if (meta === null || !SESSION_ID.test(meta.id) || path.resolve(meta.cwd) !== path.resolve(cwd)) continue;
        best = { file, modified, id: meta.id };
      }
    }
    return best === null ? null : { host: 'codex', id: best.id, transcript: best.file, resume: resumeCommand('codex', best.id) };
  }

  private async meta(file: string, modified: number): Promise<{ cwd: string; id: string } | null> {
    const kept = this.codexMetas.get(file);
    if (kept !== undefined) { kept.modified = modified; return kept.meta; }
    const head = await this.deps.files.head(file, CODEX_HEAD_BYTES);
    const meta = head === null ? null : codexMeta(head);
    this.codexMetas.set(file, { meta, modified });
    return meta;
  }

  /** How many Codex session files are remembered; tests check the bound. */
  get codexFilesKept(): number { return this.codexMetas.size; }
}

/** A locator that finds nothing, for a monitor built without one (tests that do not look at sessions). */
export const noSessions: Pick<SessionLocator, 'assign' | 'gates'> = { assign: async (processes) => processes.map(() => null), gates: async (gates) => gates.map(() => null) };

/** A user line that opens with a tag such as `<task-notification>` or `<local-command-stdout>` is the host's wrapper. */
const WRAPPER_TAG = /^<[a-z][a-z0-9-]*[\s>/]/;
const COMPACTION_SUMMARY = 'This session is being continued from a previous conversation';

export const TRANSCRIPT_TURNS_DEFAULT = 20;
export const TRANSCRIPT_TURNS_MAX = 200;
/** The most lines `?lines=` returns. */
export const TRANSCRIPT_LINES_MAX = 2000;
/** A transcript can run to tens of megabytes; the last turns are in its tail. */
export const TRANSCRIPT_TAIL_BYTES = 4 * 1024 * 1024;
/** How far the tail grows, doubling, when it holds fewer lines than asked: long tool results make few lines of many bytes. */
const TRANSCRIPT_TAIL_MAX_BYTES = 64 * 1024 * 1024;

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
 * command's caveat), the host's wrapper turns (a tag-wrapped notification, command or reminder,
 * a compaction summary), side chains (a subagent's own talk) and turns with no text (a tool call, a
 * tool result) are left out; a line cut by the tail or not JSON is skipped.
 */
export function parseTranscript(source: string, limit: number): TranscriptTurn[] {
  const turns: TranscriptTurn[] = [];
  for (const line of source.split('\n')) {
    if (line.trim() === '') continue;
    let entry: { type?: unknown; isMeta?: unknown; isSidechain?: unknown; isCompactSummary?: unknown; timestamp?: unknown; message?: { role?: unknown; content?: unknown } };
    try { entry = JSON.parse(line) as typeof entry; } catch { continue; }
    if ((entry.type !== 'user' && entry.type !== 'assistant') || entry.isMeta === true || entry.isSidechain === true || entry.isCompactSummary === true) continue;
    const text = textOf(entry.message?.content).trim();
    if (text === '') continue;
    // What the host wraps into a user line is not the owner talking: a task notification, a local command and its output, a reminder, a compaction summary.
    if (entry.type === 'user' && (WRAPPER_TAG.test(text) || text.startsWith(COMPACTION_SUMMARY))) continue;
    turns.push({ at: typeof entry.timestamp === 'string' ? entry.timestamp : null, role: entry.type, text });
  }
  return turns.slice(-limit);
}

/** The last `bytes` of a transcript from the first whole line in it, the file's size, and whether that is the whole file; null when it cannot be read. */
async function tailOf(file: string, bytes: number): Promise<{ text: string; size: number; whole: boolean } | null> {
  try {
    const handle = await open(file, 'r');
    try {
      const { size } = await handle.stat();
      const start = Math.max(0, size - bytes);
      const buffer = Buffer.alloc(size - start);
      await handle.read(buffer, 0, buffer.length, start);
      const text = buffer.toString('utf8');
      return { text: start === 0 ? text : text.slice(text.indexOf('\n') + 1), size, whole: start === 0 };
    } finally { await handle.close(); }
  } catch { return null; }
}

/** The tail of a transcript file, at most 4 MB, from the first whole line in it. */
export async function readTranscriptTail(file: string): Promise<string | null> {
  return (await tailOf(file, TRANSCRIPT_TAIL_BYTES))?.text ?? null;
}

/** A transcript entry as far as the readers look into it. */
type TranscriptEntry = { type?: unknown; isMeta?: unknown; isSidechain?: unknown; isCompactSummary?: unknown; timestamp?: unknown; message?: { role?: unknown; content?: unknown } };
type ContentPart = { type?: unknown; text?: unknown; thinking?: unknown; name?: unknown; input?: unknown; is_error?: unknown; content?: unknown };

/** The first line of a text with something on it, trimmed and capped at `TRANSCRIPT_LINE_CHARS`. */
function firstLine(text: string): string {
  const line = text.split('\n').map((entry) => entry.trim()).find((entry) => entry !== '') ?? '';
  return line.length <= TRANSCRIPT_LINE_CHARS ? line : `${line.slice(0, TRANSCRIPT_LINE_CHARS - 1)}…`;
}

/** The tools whose detail is a field of their own; any other tool shows its description or its first text input. */
const TOOL_DETAIL: Record<string, string> = { Bash: 'command', Read: 'file_path', Edit: 'file_path', MultiEdit: 'file_path', Write: 'file_path', Grep: 'pattern', Glob: 'pattern', WebFetch: 'url' };

/** `<Name> · <detail>` for a tool call, or the name alone when it has no detail. */
function toolLine(part: ContentPart): string {
  const name = typeof part.name === 'string' && part.name !== '' ? part.name : 'tool';
  const input = part.input !== null && typeof part.input === 'object' && !Array.isArray(part.input) ? part.input as Record<string, unknown> : {};
  const field = TOOL_DETAIL[name];
  const own = field === undefined ? undefined : input[field];
  const detail = typeof own === 'string' ? own
    : typeof input['description'] === 'string' ? input['description']
      : Object.values(input).find((value): value is string => typeof value === 'string') ?? '';
  const shown = firstLine(detail);
  return firstLine(shown === '' ? name : `${name} · ${shown}`);
}

/** The text of a tool result's content: the string itself, or its text parts joined. */
function resultText(content: unknown): string {
  return typeof content === 'string' ? content : textOf(content);
}

/**
 * The one line an assistant entry makes: what it said, else the tool it called, else what it
 * thought (the first line of the thinking, or `thinking` when it is empty or redacted); null for
 * an entry with none of them.
 */
function assistantLine(parts: ContentPart[], at: string | null): TranscriptLine | null {
  const said = firstLine(parts.flatMap((part) => (part.type === 'text' && typeof part.text === 'string' ? [part.text] : [])).join('\n'));
  if (said !== '') return { at, kind: 'say', text: said };
  const tool = parts.find((part) => part.type === 'tool_use');
  if (tool !== undefined) return { at, kind: 'tool', text: toolLine(tool) };
  const thought = parts.find((part) => part.type === 'thinking' || part.type === 'redacted_thinking');
  if (thought === undefined) return null;
  return { at, kind: 'think', text: firstLine(typeof thought.thinking === 'string' ? thought.thinking : '') || 'thinking' };
}

/**
 * The one line a user entry makes: what the user said, else a tool call that failed (`error:` and
 * the first line of its result); null for a tool result that went well and for the host's wrapper
 * turns (a tag-wrapped notification, command or reminder, a compaction summary).
 */
function userLine(content: unknown, at: string | null): TranscriptLine | null {
  const text = textOf(content).trim();
  if (text !== '') return WRAPPER_TAG.test(text) || text.startsWith(COMPACTION_SUMMARY) ? null : { at, kind: 'user', text: firstLine(text) };
  const parts = Array.isArray(content) ? content as ContentPart[] : [];
  const failed = parts.find((part) => part !== null && typeof part === 'object' && part.type === 'tool_result' && part.is_error === true);
  return failed === undefined ? null : { at, kind: 'result', text: firstLine(`error: ${firstLine(resultText(failed.content)) || 'no output'}`) };
}

/**
 * A claude transcript as lines, in file order, one per user or assistant entry that has one to
 * show (see `assistantLine` and `userLine`); meta lines, compaction summaries and side chains (a
 * subagent's own talk) make none, and a line cut by the tail or not JSON is skipped.
 */
export function parseTranscriptLines(source: string): TranscriptLine[] {
  const lines: TranscriptLine[] = [];
  for (const raw of source.split('\n')) {
    if (raw.trim() === '') continue;
    let entry: TranscriptEntry;
    try { entry = JSON.parse(raw) as TranscriptEntry; } catch { continue; }
    if ((entry.type !== 'user' && entry.type !== 'assistant') || entry.isMeta === true || entry.isSidechain === true || entry.isCompactSummary === true) continue;
    const at = typeof entry.timestamp === 'string' ? entry.timestamp : null;
    const content = entry.message?.content;
    const line = entry.type === 'assistant'
      ? assistantLine(Array.isArray(content) ? (content as unknown[]).filter((part): part is ContentPart => part !== null && typeof part === 'object') : typeof content === 'string' ? [{ type: 'text', text: content }] : [], at)
      : userLine(content, at);
    if (line !== null) lines.push(line);
  }
  return lines;
}

/** What `GET .../agents/<pid>/transcript` returns of a transcript, beside the session id. */
export type TranscriptRead = { turns: TranscriptTurn[]; lines: TranscriptLine[]; bytes: number; turnCount: number };

/** What the entry count of a transcript has read so far: up to `offset`, the end of its last whole line. */
type Counted = { offset: number; count: number };
/** Transcripts whose entries were counted, so a read counts only what was written since; the oldest is forgotten past this many. */
const COUNTS_KEPT = 64;
const counted = new Map<string, Counted>();

/** Whether one line of a transcript is a user or assistant entry; the cheap substring test skips parsing the rest. */
function isTurnEntry(line: string): boolean {
  if (!line.includes('"type":"user"') && !line.includes('"type":"assistant"')) return false;
  try {
    const type = (JSON.parse(line) as { type?: unknown }).type;
    return type === 'user' || type === 'assistant';
  } catch { return false; }
}

/**
 * The user and assistant entries in the whole transcript file: every one, tool calls, tool results,
 * side chains and the host's wrapper turns included. A transcript only grows, so the count is kept
 * per file and a read streams only what was written since; a file shorter than the count's end
 * was replaced, and is counted again from the start.
 */
export async function countTranscriptEntries(file: string, size: number): Promise<number> {
  const known = counted.get(file);
  let { offset, count } = known !== undefined && known.offset <= size ? known : { offset: 0, count: 0 };
  if (offset < size) {
    let carry = '';
    let at = offset;
    for await (const chunk of createReadStream(file, { start: offset, end: size - 1, encoding: 'utf8' })) {
      const lines = (carry + (chunk as string)).split('\n');
      carry = lines.pop() ?? '';
      for (const line of lines) {
        at += Buffer.byteLength(line) + 1;
        if (isTurnEntry(line)) count += 1;
      }
    }
    offset = at;
  }
  counted.delete(file);
  counted.set(file, { offset, count });
  if (counted.size > COUNTS_KEPT) counted.delete(counted.keys().next().value!);
  return count;
}

/**
 * The last `turns` turns with text and the last `lines` lines of a claude transcript, its size in
 * bytes and its count of user and assistant entries; null when it cannot be read. The tail read
 * starts at `tailBytes` (4 MB) and doubles, up to 64 MB or the whole file, while it holds fewer
 * lines than asked.
 */
export async function readTranscript(file: string, wanted: { turns: number; lines: number }, tailBytes = TRANSCRIPT_TAIL_BYTES): Promise<TranscriptRead | null> {
  let bytes = tailBytes;
  for (;;) {
    const tail = await tailOf(file, bytes);
    if (tail === null) return null;
    const lines = parseTranscriptLines(tail.text);
    if (lines.length >= wanted.lines || tail.whole || bytes >= TRANSCRIPT_TAIL_MAX_BYTES) {
      let turnCount: number;
      try { turnCount = await countTranscriptEntries(file, tail.size); } catch { return null; }
      return { turns: parseTranscript(tail.text, wanted.turns), lines: lines.slice(-wanted.lines), bytes: tail.size, turnCount };
    }
    bytes = Math.min(bytes * 2, TRANSCRIPT_TAIL_MAX_BYTES);
  }
}
