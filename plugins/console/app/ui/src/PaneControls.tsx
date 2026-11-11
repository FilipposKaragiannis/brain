import { useServices } from './console.tsx';

export const TERMINAL_PANE = 'Terminal pane';
export const TERMINAL_PANE_TITLE = 'Opens a shell in this folder in a pane at the bottom of the page. It stays open while you move between screens and projects.';

/** The buttons that open a pane in a folder the daemon lists: the project root or a worktree. */
export function PaneControls({ projectId, folder }: { projectId: string; folder: string }) {
  const { panes } = useServices();
  return <button type="button" className="button" title={TERMINAL_PANE_TITLE} onClick={() => panes.open(projectId, folder, 'shell')}>{TERMINAL_PANE}</button>;
}
