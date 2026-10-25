import { useEffect, useState } from 'react';
import type { TranscriptTurn } from '../../daemon/src/snapshot.ts';
import { projectPath, unreachableMessage } from './api.ts';
import { clockTime } from './clock.tsx';
import { useServices } from './console.tsx';
import { HTTP_OK } from './useProject.ts';

/** How many turns the fold shows. */
export const TRANSCRIPT_TURNS = 20;

type Read = { kind: 'idle' } | { kind: 'read'; turns: TranscriptTurn[] } | { kind: 'failed'; message: string };

/**
 * The last turns of an agent's claude transcript, folded under its row. Read when opened, and
 * again with every snapshot (`takenAt`) while open, so it follows the run.
 */
export function Transcript({ projectId, pid, takenAt }: { projectId: string; pid: number; takenAt: string }) {
  const { api } = useServices();
  const [open, setOpen] = useState(false);
  const [read, setRead] = useState<Read>({ kind: 'idle' });
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    void api.request(projectPath(projectId, `/agents/${pid}/transcript?lines=${TRANSCRIPT_TURNS}`), 'GET', null).then((response) => {
      if (cancelled) return;
      const turns = (response.body as { turns?: unknown } | null)?.turns;
      if (response.status === HTTP_OK && Array.isArray(turns)) { setRead({ kind: 'read', turns: turns as TranscriptTurn[] }); return; }
      const error = (response.body as { error?: unknown } | null)?.error;
      setRead({ kind: 'failed', message: typeof error === 'string' ? error : unreachableMessage(response.status) });
    });
    return () => { cancelled = true; };
  }, [api, projectId, pid, open, takenAt]);
  return (
    <details className="transcript" onToggle={(event) => setOpen((event.target as HTMLDetailsElement).open)}>
      <summary>Transcript</summary>
      {read.kind === 'failed' && <p className="muted">{read.message}.</p>}
      {read.kind === 'read' && (read.turns.length === 0 ? <p className="muted">No turn with text yet.</p> : (
        <ol className="transcript-turns" aria-label={`Transcript of pid ${pid}`}>
          {read.turns.map((turn, index) => (
            <li key={`${turn.at ?? ''}-${index}`} className={`turn turn-${turn.role}`}>
              <span className="turn-meta mono">{turn.role}{turn.at !== null ? ` · ${clockTime(turn.at)}` : ''}</span>
              <span className="turn-text">{turn.text}</span>
            </li>
          ))}
        </ol>
      ))}
    </details>
  );
}
