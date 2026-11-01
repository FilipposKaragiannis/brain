import { useState } from 'react';
import type { OpenWith } from '../../daemon/src/snapshot.ts';
import { unreachableMessage } from './api.ts';
import { useServices } from './console.tsx';
import { HTTP_OK } from './useProject.ts';

export type { OpenWith };

export const OPEN_PATH = '/api/open';

/**
 * Asks the daemon to show one file it knows (the console's settings file, its state folder, or a
 * watched project's .flow/config.yaml): in the default text editor (`with="editor"`) or selected
 * in Finder (`with="finder"`). A refusal, such as a daemon that is not on macOS, shows beside it.
 */
export function OpenFileButton({ path, with: how, label }: { path: string; with: OpenWith; label: string }) {
  const { api } = useServices();
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const open = async (): Promise<void> => {
    setBusy(true);
    const response = await api.request(OPEN_PATH, 'POST', { path, with: how });
    setBusy(false);
    const error = (response.body as { error?: unknown } | null)?.error;
    setRefusal(response.status === HTTP_OK ? null : typeof error === 'string' ? error : unreachableMessage(response.status));
  };
  return (
    <span className="action open-file">
      <button type="button" className="button" disabled={busy} onClick={() => { void open(); }}>{busy ? `${label}…` : label}</button>
      {refusal !== null && <span className="chip tone-failing" role="status" title={refusal}>{refusal}</span>}
    </span>
  );
}
