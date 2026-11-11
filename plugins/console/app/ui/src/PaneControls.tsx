import { JOBS_HOSTS } from '../../daemon/src/plugins/flow/schema.ts';
import type { JobsHost } from '../../daemon/src/plugins/flow/schema.ts';
import { useServices } from './console.tsx';

export const TERMINAL_PANE = 'Terminal pane';
export const TERMINAL_PANE_TITLE = 'Opens a shell in this folder in a pane at the bottom of the page. It stays open while you move between screens and projects.';

/** The button that starts a quick session of the host: `Quick session: claude`. */
export const quickSessionName = (host: JobsHost): string => `Quick session: ${host}`;
/** What the quick session's button says it does, with the keys its model and effort come from. */
export const quickSessionTitle = (host: JobsHost): string =>
  `Starts ${host} in this folder, in a pane at the bottom of the page, with the model and effort in jobs.${host} of .flow/config.yaml (the host's own default when unset). The pane ends when ${host} exits.`;

/** The buttons that open a pane in a folder the daemon lists: the project root or a worktree. */
export function PaneControls({ projectId, folder }: { projectId: string; folder: string }) {
  const { panes } = useServices();
  return (
    <>
      <button type="button" className="button" title={TERMINAL_PANE_TITLE} onClick={() => panes.open(projectId, folder, 'shell')}>{TERMINAL_PANE}</button>
      {JOBS_HOSTS.map((host) => (
        <button key={host} type="button" className="button" title={quickSessionTitle(host)} onClick={() => panes.open(projectId, folder, host)}>{quickSessionName(host)}</button>
      ))}
    </>
  );
}
