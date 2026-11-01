import { useEffect, useState } from 'react';
import type { TranscriptLine } from '../../daemon/src/snapshot.ts';
import { projectPath, unreachableMessage } from './api.ts';
import { clockTime } from './clock.tsx';
import { useServices } from './console.tsx';
import { HTTP_OK } from './useProject.ts';

/** How many lines the run card shows while it follows the run, and how many its full log reads. */
export const TAIL_LINES = 12;
export const FULL_LINES = 2000;

export type TranscriptRead =
  | { kind: 'reading' }
  | { kind: 'read'; lines: TranscriptLine[]; bytes: number; turnCount: number }
  | { kind: 'failed'; message: string };

/**
 * An agent's claude transcript as lines (what it said, thought and ran), read again with every
 * snapshot (`takenAt`), so the card follows the run.
 */
export function useTranscript(projectId: string, pid: number, takenAt: string, lines: number): TranscriptRead {
  const { api } = useServices();
  const [read, setRead] = useState<TranscriptRead>({ kind: 'reading' });
  useEffect(() => {
    let cancelled = false;
    void api.request(projectPath(projectId, `/agents/${pid}/transcript?lines=${lines}`), 'GET', null).then((response) => {
      if (cancelled) return;
      const body = response.body as { lines?: unknown; bytes?: unknown; turnCount?: unknown; error?: unknown } | null;
      if (response.status === HTTP_OK && Array.isArray(body?.lines)) {
        setRead({ kind: 'read', lines: body.lines as TranscriptLine[], bytes: Number(body.bytes ?? 0), turnCount: Number(body.turnCount ?? 0) });
        return;
      }
      setRead({ kind: 'failed', message: typeof body?.error === 'string' ? body.error : unreachableMessage(response.status) });
    });
    return () => { cancelled = true; };
  }, [api, projectId, pid, takenAt, lines]);
  return read;
}

/** The transcript as a terminal: time, what kind of line, and its text; the last row says the run is live. */
export function RunStream({ read, pid, full }: { read: TranscriptRead; pid: number; full: boolean }) {
  return (
    <div className={full ? 'run-stream full' : 'run-stream'}>
      {read.kind === 'reading' && <p className="stream-note">Reading the transcript…</p>}
      {read.kind === 'failed' && <p className="stream-note">{read.message}.</p>}
      {read.kind === 'read' && (
        <ol className="stream-lines" aria-label={`Transcript of pid ${pid}`}>
          {read.lines.map((line, index) => (
            <li key={`${line.at ?? ''}-${index}`} className={`stream-line kind-${line.kind}`}>
              <span className="stream-time">{line.at === null ? '' : clockTime(line.at)}</span>
              <span className="stream-kind">{line.kind}</span>
              <span className="stream-text" title={line.text}>{line.text}</span>
            </li>
          ))}
          <li className="stream-line kind-live" aria-label="Live">
            <span className="stream-time" />
            <span className="stream-kind">live</span>
            <span className="stream-text">working<span className="stream-cursor" aria-hidden="true">▌</span></span>
          </li>
        </ol>
      )}
    </div>
  );
}

/** A transcript's size, as the card's stats show it. */
export function transcriptSize(bytes: number): string {
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(2)} MB`;
  if (bytes >= 1_000) return `${Math.round(bytes / 1_000)} KB`;
  return `${bytes} B`;
}
