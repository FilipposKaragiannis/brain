import { useEffect, useState } from 'react';
import type { FlowEvent } from '../../daemon/src/snapshot.ts';
import { DAEMON_RETRY_MS, projectPath, unreachableMessage } from './api.ts';
import { useServices } from './console.tsx';
import { HTTP_OK } from './useProject.ts';

/** The most the daemon hands back in one read, its own cap. */
export const EVENTS_LIMIT = 200;
const HTTP_UNAUTHORIZED = 401;

export type EventPage = { events: FlowEvent[]; total: number; kept: number };

/** The last page read, kept through a failed read, and why the latest read failed, if it did. */
export type EventLog = { page: EventPage | null; error: string | null };

/**
 * The kept events of a project, newest first, only `item`'s when one is given. It reads again
 * whenever `revision` changes, and every ten seconds while a read fails, so a daemon that comes
 * back clears the error by itself.
 */
export function useEventLog(projectId: string, item: string | null, revision: string): EventLog {
  const { api } = useServices();
  const [log, setLog] = useState<EventLog>({ page: null, error: null });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let cancelled = false;
    const query = item === null ? '' : `&item=${encodeURIComponent(item)}`;
    void api.request(projectPath(projectId, `/events?limit=${EVENTS_LIMIT}${query}`), 'GET', null).then((response) => {
      if (cancelled) return;
      if (response.status === HTTP_OK && isEventPage(response.body)) { setLog({ page: response.body, error: null }); return; }
      const error = failureMessage(response.status, response.body);
      setLog((current) => ({ page: current.page, error }));
    });
    return () => { cancelled = true; };
  }, [api, projectId, item, revision, attempt]);
  useEffect(() => {
    if (log.error === null) return;
    const retry = setTimeout(() => setAttempt((count) => count + 1), DAEMON_RETRY_MS);
    return () => clearTimeout(retry);
  }, [log]);
  return log;
}

function isEventPage(body: unknown): body is EventPage {
  return typeof body === 'object' && body !== null && Array.isArray((body as { events?: unknown }).events);
}

function failureMessage(status: number, body: unknown): string {
  const error = (body as { error?: unknown } | null)?.error;
  if (status === 0 || status === HTTP_UNAUTHORIZED || typeof error !== 'string' || error === '') return unreachableMessage(status);
  return `The events could not be read: ${error}`;
}
