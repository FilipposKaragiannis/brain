import type { TranscriptLine, TranscriptTurn } from '../snapshot.ts';
import { TRANSCRIPT_LINE_CHARS } from '../snapshot.ts';

/** What a host's reader makes of a transcript's text: its lines, and its last `limit` turns with text on asking. */
export type ParsedTranscript = { lines: TranscriptLine[]; turns: (limit: number) => TranscriptTurn[] };

/** The first line of a text with something on it, trimmed and capped at `TRANSCRIPT_LINE_CHARS`. */
export function firstLine(text: string): string {
  const line = text.split('\n').map((entry) => entry.trim()).find((entry) => entry !== '') ?? '';
  return line.length <= TRANSCRIPT_LINE_CHARS ? line : `${line.slice(0, TRANSCRIPT_LINE_CHARS - 1)}…`;
}

/** `<name> · <detail>` capped to one line, or the name alone when the detail is empty. */
export function namedLine(name: string, detail: string): string {
  const shown = firstLine(detail);
  return firstLine(shown === '' ? name : `${name} · ${shown}`);
}
