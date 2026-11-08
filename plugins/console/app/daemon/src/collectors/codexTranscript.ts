import type { TranscriptLine, TranscriptTurn } from '../snapshot.ts';
import type { ParsedTranscript } from './transcriptLine.ts';
import { firstLine, namedLine } from './transcriptLine.ts';

/** A Codex session entry as far as the readers look into it: `{timestamp, type, payload}`, one per line. */
type CodexEntry = { timestamp?: unknown; type?: unknown; payload?: CodexPayload };
type CodexPayload = { type?: unknown; role?: unknown; item?: CodexItem; content?: unknown; summary?: unknown; name?: unknown; arguments?: unknown; input?: unknown };
type CodexItem = {
  type?: unknown; content?: unknown; summary_text?: unknown; command?: unknown; status?: unknown; exit_code?: unknown;
  server?: unknown; tool?: unknown; arguments?: unknown; result?: unknown; error?: unknown; kind?: unknown; query?: unknown;
};
/** A Codex message, tool call or reasoning entry: what its readable record (`item_completed`) or its model record (`response_item`) holds. */
type CodexMessage = { role: TranscriptTurn['role']; text: string };
/** An entry of a session's text with its time. */
type TimedEntry = { at: string | null; entry: CodexEntry };

/** Codex 0.16x writes each finished item as an `item_completed` event beside the model's own `response_item`; a file with any reads from those alone. */
const CODEX_ITEM_EVENT = '"type":"item_completed"';
/** What Codex writes at the top of a user message that is its own context, not the owner talking: the AGENTS.md it read, or a tag such as `<environment_context>`. */
const CODEX_AGENTS_PREAMBLE = '# AGENTS.md instructions';
const CODEX_WRAPPER_TAG = /^<[a-z][a-z0-9_-]*[\s>/]/;
/** The model record of a developer message or the tool list: Codex's own instructions, never a turn. */
const CODEX_DEVELOPER = 'developer';
const CODEX_TOOL_LIST = 'additional_tools';
/** The model records of a tool call. */
const CODEX_CALLS: readonly unknown[] = ['function_call', 'custom_tool_call'];
/** A shell flag that makes the next argument the script: `zsh -lc "<script>"`. */
const SHELL_SCRIPT_FLAGS: readonly string[] = ['-c', '-lc'];
/** `<shell> <flag> "<script>"` is three words. */
const SHELL_SCRIPT_WORDS = 3;
/** The name a tool call without one shows. */
const UNNAMED_TOOL = 'tool';

/** The strings of a list, or of the `text` fields of its parts (`input_text`, `output_text`, `text`, `Text`, `summary_text` alike). */
function codexTexts(content: unknown): string[] {
  if (!Array.isArray(content)) return [];
  return content.flatMap((part: unknown) => {
    if (typeof part === 'string') return [part];
    const text = part !== null && typeof part === 'object' ? (part as { text?: unknown }).text : undefined;
    return typeof text === 'string' ? [text] : [];
  });
}

/** A value when it is a string with something in it, else `fallback`. */
function textOr(value: unknown, fallback: string): string {
  return typeof value === 'string' && value !== '' ? value : fallback;
}

/** The first string among an object's values, or `''`. */
function firstText(value: unknown): string {
  if (value === null || typeof value !== 'object') return '';
  return Object.values(value as Record<string, unknown>).find((entry): entry is string => typeof entry === 'string') ?? '';
}

/** A command as the owner would type it: the script of `<shell> -lc "<script>"`, else the words joined. */
function shellCommand(command: unknown): string {
  if (typeof command === 'string') return command;
  if (!Array.isArray(command)) return '';
  const words = command.filter((word): word is string => typeof word === 'string');
  const [, flag, script] = words;
  return words.length === SHELL_SCRIPT_WORDS && SHELL_SCRIPT_FLAGS.includes(flag!) ? script! : words.join(' ');
}

/** The line a message makes: `user` for the owner or the prompt, `say` for Codex. */
function messageLine(message: CodexMessage, at: string | null): TranscriptLine {
  return { at, kind: message.role === 'user' ? 'user' : 'say', text: firstLine(message.text) };
}

/** The line reasoning makes: its summary's first line, or that it thought. */
function thoughtLine(summary: unknown, at: string | null): TranscriptLine {
  return { at, kind: 'think', text: firstLine(codexTexts(summary).join('\n')) || 'thinking' };
}

/** The `error:` line after a command or tool that failed, with the first line of what it said. */
function errorLine(said: string, at: string | null): TranscriptLine {
  return { at, kind: 'result', text: firstLine(`error: ${firstLine(said) || 'no output'}`) };
}

/** The message of a readable record: what the owner or the prompt said (`UserMessage`) or what Codex said (`AgentMessage`). */
function codexItemMessage(item: CodexItem): CodexMessage | null {
  if (item.type !== 'UserMessage' && item.type !== 'AgentMessage') return null;
  const text = codexTexts(item.content).join('\n').trim();
  return text === '' ? null : { role: item.type === 'UserMessage' ? 'user' : 'assistant', text };
}

/** The message of a model record: an assistant's output text, or a user's input text without Codex's own context parts. */
function codexResponseMessage(payload: CodexPayload): CodexMessage | null {
  if (payload.type !== 'message' || (payload.role !== 'user' && payload.role !== 'assistant')) return null;
  const parts = codexTexts(payload.content).filter((text) => payload.role === 'assistant' || (!CODEX_WRAPPER_TAG.test(text.trim()) && !text.startsWith(CODEX_AGENTS_PREAMBLE)));
  const text = parts.join('\n').trim();
  return text === '' ? null : { role: payload.role, text };
}

/** A `UserMessage` or `AgentMessage` record: its first line, or none when it has no text. */
function messageLines(item: CodexItem, at: string | null): TranscriptLine[] {
  const message = codexItemMessage(item);
  return message === null ? [] : [messageLine(message, at)];
}

/** A `Reasoning` record: its summary, or that it thought. */
function reasoningLines(item: CodexItem, at: string | null): TranscriptLine[] {
  return [thoughtLine(item.summary_text, at)];
}

/** A `CommandExecution` record: `shell · <script>`, and its exit code after one that failed. */
function commandLines(item: CodexItem, at: string | null): TranscriptLine[] {
  const ran: TranscriptLine = { at, kind: 'tool', text: namedLine('shell', shellCommand(item.command)) };
  const exitCode = typeof item.exit_code === 'number' ? item.exit_code : null;
  if (item.status !== 'failed' && (exitCode === null || exitCode === 0)) return [ran];
  return [ran, { at, kind: 'result', text: `error: exit code ${exitCode ?? 'unknown'}` }];
}

/** An `McpToolCall` record: `<server>.<tool> · <first text argument>`, and its error after one that failed. */
function toolCallLines(item: CodexItem, at: string | null): TranscriptLine[] {
  const name = [item.server, item.tool].filter((part): part is string => typeof part === 'string' && part !== '').join('.') || UNNAMED_TOOL;
  const called: TranscriptLine = { at, kind: 'tool', text: namedLine(name, firstText(item.arguments)) };
  const result = item.result !== null && typeof item.result === 'object' ? item.result as { isError?: unknown; content?: unknown } : {};
  if (item.status !== 'failed' && result.isError !== true) return [called];
  return [called, errorLine(typeof item.error === 'string' ? item.error : codexTexts(result.content).join('\n'), at)];
}

/** An `Extension` record: its kind and its query. */
function extensionLines(item: CodexItem, at: string | null): TranscriptLine[] {
  return [{ at, kind: 'tool', text: namedLine(textOr(item.kind, UNNAMED_TOOL), textOr(item.query, '')) }];
}

/** The lines each kind of readable record makes; any other kind makes none. */
const ITEM_LINES = new Map<unknown, (item: CodexItem, at: string | null) => TranscriptLine[]>([
  ['UserMessage', messageLines],
  ['AgentMessage', messageLines],
  ['Reasoning', reasoningLines],
  ['CommandExecution', commandLines],
  ['McpToolCall', toolCallLines],
  ['Extension', extensionLines],
]);

/** The lines of one readable record: a message, its reasoning, a command or tool it ran, and an `error:` line after one that failed. */
function codexItemLines(item: CodexItem, at: string | null): TranscriptLine[] {
  return ITEM_LINES.get(item.type)?.(item, at) ?? [];
}

/** The detail of parsed tool call arguments: the command they run, else their first text argument. */
function argumentsDetail(parsed: unknown): string {
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return '';
  const record = parsed as Record<string, unknown>;
  const command = shellCommand(record['cmd'] ?? record['command']);
  return command !== '' ? command : firstText(record);
}

/** The detail of a model record's tool call: the command it runs, else its first text argument, else its raw input. */
function codexCallDetail(payload: CodexPayload): string {
  if (typeof payload.input === 'string') return payload.input;
  if (typeof payload.arguments !== 'string') return '';
  let parsed: unknown;
  try { parsed = JSON.parse(payload.arguments); } catch { return payload.arguments; }
  return argumentsDetail(parsed);
}

/** The line of one model record: a message, a tool call with its command, or its reasoning; outputs and Codex's own instructions make none. */
function codexResponseLine(payload: CodexPayload, at: string | null): TranscriptLine | null {
  const message = codexResponseMessage(payload);
  if (message !== null) return messageLine(message, at);
  if (CODEX_CALLS.includes(payload.type)) return { at, kind: 'tool', text: namedLine(textOr(payload.name, UNNAMED_TOOL), codexCallDetail(payload)) };
  return payload.type === 'reasoning' ? thoughtLine(payload.summary, at) : null;
}

/** Each entry of a Codex session's text with its time, in file order; a line cut by the tail or not JSON is skipped. */
function codexEntries(source: string): TimedEntry[] {
  const entries: TimedEntry[] = [];
  for (const raw of source.split('\n')) {
    if (raw.trim() === '') continue;
    try {
      const entry = JSON.parse(raw) as CodexEntry;
      if (entry !== null && typeof entry === 'object') entries.push({ at: typeof entry.timestamp === 'string' ? entry.timestamp : null, entry });
    } catch { continue; }
  }
  return entries;
}

/** The readable record of an entry, or null when it is not one (an `event_msg` of type `item_completed`). */
function completedItem(entry: CodexEntry): CodexItem | null {
  return entry.type === 'event_msg' && entry.payload?.type === 'item_completed' && entry.payload.item !== null && typeof entry.payload.item === 'object' ? entry.payload.item : null;
}

/** The model record of an entry, or null when it is not one. */
function responseItem(entry: CodexEntry): CodexPayload | null {
  return entry.type === 'response_item' && entry.payload !== null && typeof entry.payload === 'object' ? entry.payload : null;
}

/** How a session's entries are read: its readable records (Codex 0.16x) or its model records. */
type EntryReader = { lines: (entry: CodexEntry, at: string | null) => TranscriptLine[]; message: (entry: CodexEntry) => CodexMessage | null };
const ITEM_READER: EntryReader = {
  lines: (entry, at) => { const item = completedItem(entry); return item === null ? [] : codexItemLines(item, at); },
  message: (entry) => { const item = completedItem(entry); return item === null ? null : codexItemMessage(item); },
};
const RESPONSE_READER: EntryReader = {
  lines: (entry, at) => { const payload = responseItem(entry); const line = payload === null ? null : codexResponseLine(payload, at); return line === null ? [] : [line]; },
  message: (entry) => { const payload = responseItem(entry); return payload === null ? null : codexResponseMessage(payload); },
};

/**
 * A Codex session (`~/.codex/sessions/<day>/rollout-*.jsonl`), its text parsed once: its lines in
 * file order (what was said, the reasoning's summary or that it thought, each command with its
 * script and each tool with its first text argument, and an `error:` line after one that failed),
 * and its last turns with text. A text that holds any `item_completed` event (Codex 0.16x) is read
 * from those alone, as they say each command plainly; an older one from its `response_item` entries
 * (messages, tool calls, reasoning), where a tool's failure is not written plainly and so not shown.
 * Codex's own instructions and the context it puts in a user message (AGENTS.md, a tag-wrapped
 * environment) make no line or turn.
 */
export function parseCodexTranscript(source: string): ParsedTranscript {
  const entries = codexEntries(source);
  const reader = source.includes(CODEX_ITEM_EVENT) ? ITEM_READER : RESPONSE_READER;
  const turns = (limit: number): TranscriptTurn[] => entries
    .flatMap(({ at, entry }) => { const message = reader.message(entry); return message === null ? [] : [{ at, role: message.role, text: message.text }]; })
    .slice(-limit);
  return { lines: entries.flatMap(({ at, entry }) => reader.lines(entry, at)), turns };
}

/** Whether one line of a Codex session is a model record other than Codex's own instructions; the cheap substring test skips parsing the rest. */
export function isCodexEntry(line: string): boolean {
  if (!line.includes('"type":"response_item"')) return false;
  try {
    const entry = JSON.parse(line) as CodexEntry;
    return entry.type === 'response_item' && entry.payload?.role !== CODEX_DEVELOPER && entry.payload?.type !== CODEX_TOOL_LIST;
  } catch { return false; }
}
