import type { FlowEvent } from './snapshot.ts';

/**
 * events.log lines: `<iso time>\t<item or ->\t<kind>\t<message>`, oldest first. The parser
 * returns the newest first and skips any line that does not have the four fields.
 */
export function parseEvents(source: string, keep: number): FlowEvent[] {
  const events: FlowEvent[] = [];
  for (const line of source.split('\n')) {
    const fields = line.split('\t');
    const at = fields[0];
    const item = fields[1];
    const kind = fields[2];
    if (at === undefined || item === undefined || kind === undefined || fields.length < 4) continue;
    if (!/^\d{4}-\d{2}-\d{2}T/.test(at)) continue;
    events.push({ at, item: item === '-' ? null : item, kind, message: fields.slice(3).join('\t') });
  }
  return events.reverse().slice(0, keep);
}
