import { useEffect, useState } from 'react';
import type { FlowEvent } from '../../daemon/src/snapshot.ts';
import { projectPath } from './api.ts';
import { useServices } from './console.tsx';
import { HTTP_OK } from './useProject.ts';

/** The most the daemon hands back in one read, its own cap. */
export const EVENTS_LIMIT = 200;

export type EventLog =
  | { kind: 'loading' }
  | { kind: 'loaded'; events: FlowEvent[]; total: number; kept: number }
  | { kind: 'failed'; message: string };

/**
 * The kept events of a project, newest first, only `item`'s when one is given. It reads again
 * whenever `revision` changes, so the list follows the snapshot's newest event.
 */
export function useEventLog(projectId: string, item: string | null, revision: string): EventLog {
  const { api } = useServices();
  const [log, setLog] = useState<EventLog>({ kind: 'loading' });
  useEffect(() => {
    let cancelled = false;
    const query = item === null ? '' : `&item=${encodeURIComponent(item)}`;
    void api.request(projectPath(projectId, `/events?limit=${EVENTS_LIMIT}${query}`), 'GET', null).then((response) => {
      if (cancelled) return;
      if (response.status === HTTP_OK && isEventPage(response.body)) { setLog({ kind: 'loaded', ...response.body }); return; }
      setLog({ kind: 'failed', message: failureMessage(response.status, response.body) });
    });
    return () => { cancelled = true; };
  }, [api, projectId, item, revision]);
  return log;
}

function isEventPage(body: unknown): body is { events: FlowEvent[]; total: number; kept: number } {
  return typeof body === 'object' && body !== null && Array.isArray((body as { events?: unknown }).events);
}

function failureMessage(status: number, body: unknown): string {
  const error = (body as { error?: unknown } | null)?.error;
  if (typeof error === 'string' && error !== '') return `The events could not be read: ${error}`;
  return status === 0 ? 'The daemon did not answer' : `The daemon answered ${status}`;
}
