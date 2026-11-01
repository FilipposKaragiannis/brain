import { useEffect, useRef, useState } from 'react';
import { projectPath, unreachableMessage } from './api.ts';
import { useServices } from './console.tsx';

export const REFRESH_ALL_SOURCES = 'Refresh all sources';
export const REFRESH_TITLE = 'Read every source again now; the freshness below updates as each read lands';
/** How long the icon keeps turning after the daemon took the request, so a fast answer still shows. */
export const REFRESH_SETTLE_MS = 1200;
const HTTP_ACCEPTED = 202;

/**
 * The Sources module's small refresh button: asks the daemon to read every source again
 * (`POST /api/projects/<id>/refresh`, no source named). It is disabled and turning while the
 * request is out and for a moment after; a refusal shows a short line beside it. The snapshot
 * stream brings the new freshness by itself.
 */
export function SourcesRefresh({ projectId }: { projectId: string }) {
  const { api } = useServices();
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const settle = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (settle.current !== null) clearTimeout(settle.current); }, []);
  const refresh = async (): Promise<void> => {
    setBusy(true);
    setFailure(null);
    const response = await api.request(projectPath(projectId, '/refresh'), 'POST', null);
    if (response.status !== HTTP_ACCEPTED) {
      const error = (response.body as { error?: unknown } | null)?.error;
      setFailure(`Refresh failed: ${typeof error === 'string' ? error : unreachableMessage(response.status)}`);
      setBusy(false);
      return;
    }
    settle.current = setTimeout(() => { settle.current = null; setBusy(false); }, REFRESH_SETTLE_MS);
  };
  return (
    <span className="sources-refresh">
      {failure !== null && <span className="refresh-error" role="status" title={failure}>{failure}</span>}
      <button type="button" className={busy ? 'icon-button small spinning' : 'icon-button small'} aria-label={REFRESH_ALL_SOURCES} title={REFRESH_TITLE} disabled={busy} onClick={() => { void refresh(); }}>
        <svg className="icon" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
          <path d="M21 4v6h-6" />
          <path d="M20.5 15a9 9 0 1 1-2.1-9.4L21 10" />
        </svg>
      </button>
    </span>
  );
}
