import type { PaneTarget } from '../../daemon/src/paneProtocol.ts';
import { useServices } from './console.tsx';

/** The label every button that opens a shell pane in a folder carries. */
export const OPEN_IN_TERMINAL = 'Open in Terminal';
export const OPEN_IN_TERMINAL_TITLE = 'Opens a shell in this folder in a pane at the bottom of the page. It stays open while you move between screens and projects.';
export const FOLLOW_LOG = 'Follow log';
export const FOLLOW_LOG_TITLE = "Follows the job's log in a pane at the bottom of the page.";
export const OPEN_SESSION = 'Open session';
export const OPEN_SESSION_LIVE = 'Opens a pane in the folder the session ran in and shows its resume command. The run is still going, so run it once the run ends.';
export const OPEN_SESSION_ENDED = 'Opens a pane in the folder the session ran in and resumes the session.';

type PaneButtonProps = { projectId: string; target: PaneTarget; label: string; title: string; primary: boolean };

/** A button that opens a pane in the dock: the page names what to open, the daemon plans what runs. */
export function PaneButton({ projectId, target, label, title, primary }: PaneButtonProps) {
  const { panes } = useServices();
  return <button type="button" className={primary ? 'button primary' : 'button'} title={title} onClick={() => panes.open(projectId, target)}>{label}</button>;
}

/** Opens a shell pane in a folder the snapshot lists: the project root, a worktree, or the folder of an agent or session. */
export function TerminalButton({ projectId, folder }: { projectId: string; folder: string }) {
  return <PaneButton projectId={projectId} target={{ run: 'shell', folder }} label={OPEN_IN_TERMINAL} title={OPEN_IN_TERMINAL_TITLE} primary={false} />;
}

/** Opens a pane that follows a job's log from the project root. */
export function JobLogButton({ projectId, job }: { projectId: string; job: string }) {
  return <PaneButton projectId={projectId} target={{ run: 'job', job }} label={FOLLOW_LOG} title={FOLLOW_LOG_TITLE} primary={false} />;
}

/**
 * Hands the owner an agent's session: a pane in the folder it ran in with its resume command,
 * shown but not run while the process still runs, run at once once it has ended.
 */
export function SessionButton({ projectId, folder, pid, alive }: { projectId: string; folder: string; pid: number; alive: boolean }) {
  return <PaneButton projectId={projectId} target={{ run: 'session', folder, pid }} label={OPEN_SESSION} title={alive ? OPEN_SESSION_LIVE : OPEN_SESSION_ENDED} primary />;
}
