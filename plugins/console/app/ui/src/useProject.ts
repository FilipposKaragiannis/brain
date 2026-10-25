import { useEffect, useState } from 'react';
import type { Snapshot } from '../../daemon/src/snapshot.ts';
import { projectPath } from './api.ts';
import { useServices } from './console.tsx';
import type { LinkState } from './stream.ts';

export const POLL_MS = 30000;
export const HTTP_OK = 200;

export type ProjectView = { snapshot: Snapshot | null; connected: boolean; link: LinkState };

const ignore = (): void => {};

/**
 * The latest snapshot of one project. It listens on the event stream; when the stream drops it
 * reads `/snapshot` at once and every 30 s, trying the stream again on each tick, until it is back.
 */
export function useProject(projectId: string): ProjectView {
  const { api, hub } = useServices();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [link, setLink] = useState<LinkState>('connecting');

  useEffect(() => {
    setSnapshot(null);
    return hub.subscribe(projectId, { snapshot: setSnapshot, action: ignore, link: setLink });
  }, [hub, projectId]);

  useEffect(() => {
    if (link !== 'down') return;
    let cancelled = false;
    const poll = async (): Promise<void> => {
      const response = await api.request(projectPath(projectId, '/snapshot'), 'GET', null);
      if (!cancelled && response.status === HTTP_OK && isSnapshot(response.body)) setSnapshot(response.body);
    };
    void poll();
    const timer = setInterval(() => { void poll(); hub.reconnect(projectId); }, POLL_MS);
    return () => { cancelled = true; clearInterval(timer); };
  }, [api, hub, projectId, link]);

  return { snapshot, connected: link === 'open', link };
}

function isSnapshot(body: unknown): body is Snapshot {
  return typeof body === 'object' && body !== null && typeof (body as { takenAt?: unknown }).takenAt === 'string';
}
