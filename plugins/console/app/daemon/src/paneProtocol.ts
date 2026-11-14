/**
 * The terminal pane's wire, shared by the daemon and the page. One WebSocket per pane: binary
 * frames are terminal bytes both ways, text frames are JSON, `PaneControl` up and `PaneNotice`
 * down. No node imports, so the page imports this file as it imports `snapshot.ts`.
 */

/** What a pane runs: a login shell in a folder, a job's log followed, or an agent's session resumed, named by its pid or by the gate it raised. */
export const PANE_RUNS = ['shell', 'job', 'session', 'gate'] as const;
export type PaneRun = (typeof PANE_RUNS)[number];

/**
 * What a pane opens, as the page names it: a folder, a job, a session by its pid and the folder it
 * ran in, or a gate by its item. Never a command line: the daemon plans the argv from its own facts.
 */
export type PaneTarget =
  | { run: 'shell'; folder: string }
  | { run: 'job'; job: string }
  | { run: 'session'; folder: string; pid: number }
  | { run: 'gate'; item: string };

/** The query field that carries each part of a target, beside `run`. */
export const TARGET_FIELDS = { folder: 'path', job: 'job', pid: 'session', item: 'gate' } as const;

/** A target as the query of its pane's request. */
export function targetQuery(target: PaneTarget): Record<string, string> {
  switch (target.run) {
    case 'shell': return { run: target.run, [TARGET_FIELDS.folder]: target.folder };
    case 'job': return { run: target.run, [TARGET_FIELDS.job]: target.job };
    case 'session': return { run: target.run, [TARGET_FIELDS.folder]: target.folder, [TARGET_FIELDS.pid]: String(target.pid) };
    case 'gate': return { run: target.run, [TARGET_FIELDS.item]: target.item };
  }
}

export type PaneSize = { columns: number; rows: number };

/** Up: the terminal's new size, or how many bytes the page drew since its last ack. `cols` is the wire's name for its columns. */
export type PaneControl = { type: 'resize'; cols: number; rows: number } | { type: 'ack'; bytes: number };

/** Down: the first frame of an accepted pane, the only frame of a refused one, or the process's end. */
export type PaneNotice =
  | { type: 'started'; pane: string; command: string[]; folder: string }
  | { type: 'refused'; error: string }
  | { type: 'exit'; code: number | null; signal: string | null };

/** How a pane's socket closes, and why. */
export const PANE_CLOSE = {
  /** The process ended; an `exit` frame came first. */
  ended: 1000,
  daemonStopping: 1001,
  /** A frame the daemon does not take. */
  unknownFrame: 1008,
  /** The pane was refused; a `refused` frame came first. */
  refused: 4400,
  /** The project is no longer watched. */
  projectGone: 4404,
} as const;

/** Panes open at once across the daemon, every project together. */
export const MAXIMUM_PANES = 4;
/** How long a hung-up pane's processes get before SIGKILL. */
export const PANE_KILL_GRACE_MILLISECONDS = 1500;
/** Bytes sent and not yet acked above which the daemon pauses the pty. */
export const OUTPUT_HIGH_WATER_BYTES = 1024 * 1024;
/** Bytes sent and not yet acked under which a paused pty resumes. */
export const OUTPUT_LOW_WATER_BYTES = 256 * 1024;
/** How often a paused pty checks whether its process ended, well inside the 200 ms after which node-pty drops what it still holds. */
export const PAUSED_EXIT_CHECK_MILLISECONDS = 50;
/** How many drawn bytes the page acks at a time. */
export const ACK_EVERY_BYTES = 64 * 1024;
/** The largest frame the daemon takes from the page. */
export const INPUT_FRAME_LIMIT_BYTES = 1024 * 1024;

export const MINIMUM_PANE_COLUMNS = 2;
export const MAXIMUM_PANE_COLUMNS = 500;
export const MINIMUM_PANE_ROWS = 1;
export const MAXIMUM_PANE_ROWS = 300;
/** The size of a pane whose request names none. */
export const DEFAULT_PANE_COLUMNS = 80;
export const DEFAULT_PANE_ROWS = 24;
