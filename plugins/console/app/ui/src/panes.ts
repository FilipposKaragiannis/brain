import type { PaneNotice, PaneRun, PaneSize } from '../../daemon/src/paneProtocol.ts';
import { ACK_EVERY_BYTES, PANE_CLOSE } from '../../daemon/src/paneProtocol.ts';
import { projectPath } from './api.ts';
import type { Api, SocketLike } from './api.ts';

/** A terminal emulator as a pane uses it. It owns its host element, so it survives being shown again. */
export type TerminalLike = {
  /** Puts the terminal in the container: opens it there the first time, moves it there after. */
  showIn(container: HTMLElement): void;
  /** Fits the terminal to its container and returns the size it now has. */
  fit(): PaneSize;
  /** Draws the bytes, then calls `drawn`. */
  write(bytes: Uint8Array, drawn: () => void): void;
  /** Hears what the owner types, as bytes. */
  onInput(listener: (bytes: Uint8Array) => void): void;
  focus(): void;
  dispose(): void;
};

export type TerminalFactory = () => TerminalLike;

/** `opening` until the daemon started the process, `live` while it runs, `ended` with the reason after. */
export type PaneState = 'opening' | 'live' | 'ended';

export type PaneView = { key: string; projectId: string; folder: string; run: PaneRun; state: PaneState; command: string[]; ended: string | null };

/** What an ended pane says, by how it ended. An exit adds its code or signal to `sessionEnded`; a refusal says the daemon's words. */
export const PANE_END_WORDS = {
  sessionEnded: 'Session ended',
  daemonStopped: 'The daemon stopped',
  projectGone: 'The project is no longer watched',
  connectionLost: 'Connection to the daemon lost',
} as const;

const NOTICE_TYPES: ReadonlySet<string> = new Set<PaneNotice['type']>(['started', 'refused', 'exit']);

type Pane = { view: PaneView; terminal: TerminalLike; socket: SocketLike | null; drawnSinceAck: number };

/**
 * The page's open panes, across projects, each with its terminal and its one socket to the daemon.
 * A pane opens its socket only once it is attached and fitted, so the process starts at the
 * terminal's size; it lives until `close` and keeps its screen after the daemon ended it.
 */
export class PaneStore {
  private readonly api: Api;
  private readonly terminals: TerminalFactory;
  private readonly entries = new Map<string, Pane>();
  private readonly listeners = new Set<() => void>();
  private views: readonly PaneView[] = [];
  private opened = 0;

  constructor(api: Api, terminals: TerminalFactory) {
    this.api = api;
    this.terminals = terminals;
  }

  /** Adds an `opening` pane and returns its key; nothing reaches the daemon until `attach`. */
  open(projectId: string, folder: string, run: PaneRun): string {
    this.opened += 1;
    const key = `pane-${this.opened}`;
    const view: PaneView = { key, projectId, folder, run, state: 'opening', command: [], ended: null };
    this.entries.set(key, { view, terminal: this.terminals(), socket: null, drawnSinceAck: 0 });
    this.publish();
    return key;
  }

  /** Shows the pane's terminal in the container; the first time, fits it and opens the pane's socket at that size. */
  attach(key: string, container: HTMLElement): void {
    const pane = this.entries.get(key);
    if (pane === undefined) return;
    pane.terminal.showIn(container);
    if (pane.socket !== null) return;
    const size = pane.terminal.fit();
    const socket = this.api.openSocket(paneSocketPath(pane.view, size));
    pane.socket = socket;
    socket.onmessage = (event) => this.receive(pane, socket, event);
    socket.onclose = (event) => this.end(pane, closeWords(event.code));
    pane.terminal.onInput((bytes) => { if (pane.view.state === 'live') socket.send(bytes); });
  }

  /** Fits the pane's terminal again, and tells the daemon the new size while the process runs. */
  refit(key: string): void {
    const pane = this.entries.get(key);
    if (pane === undefined) return;
    const size = pane.terminal.fit();
    if (pane.socket === null || pane.view.state !== 'live') return;
    pane.socket.send(JSON.stringify({ type: 'resize', cols: size.cols, rows: size.rows }));
  }

  /** Ends the pane's socket, which hangs up its process, and drops the pane. */
  close(key: string): void {
    const pane = this.entries.get(key);
    if (pane === undefined) return;
    this.entries.delete(key);
    if (pane.socket !== null) {
      pane.socket.onmessage = null;
      pane.socket.onclose = null;
      pane.socket.close(PANE_CLOSE.ended);
    }
    pane.terminal.dispose();
    this.publish();
  }

  /** The panes in the order they opened; the same array until one changes, for `useSyncExternalStore`. */
  panes(): readonly PaneView[] {
    return this.views;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  private receive(pane: Pane, socket: SocketLike, event: MessageEvent): void {
    const data: unknown = event.data;
    if (data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(data);
      pane.terminal.write(bytes, () => this.countDrawn(pane, socket, bytes.byteLength));
      return;
    }
    if (typeof data !== 'string') return;
    const notice = parseNotice(data);
    if (notice === null) return;
    if (notice.type === 'started') { this.change(pane, { ...pane.view, state: 'live', command: notice.command }); return; }
    if (notice.type === 'refused') { this.end(pane, notice.error); return; }
    this.end(pane, exitWords(notice.code, notice.signal));
  }

  private countDrawn(pane: Pane, socket: SocketLike, byteCount: number): void {
    if (this.entries.get(pane.view.key) !== pane || pane.view.state === 'ended') return;
    pane.drawnSinceAck += byteCount;
    if (pane.drawnSinceAck < ACK_EVERY_BYTES) return;
    socket.send(JSON.stringify({ type: 'ack', bytes: pane.drawnSinceAck }));
    pane.drawnSinceAck = 0;
  }

  private end(pane: Pane, words: string): void {
    if (pane.view.state === 'ended') return;
    this.change(pane, { ...pane.view, state: 'ended', ended: words });
  }

  private change(pane: Pane, view: PaneView): void {
    pane.view = view;
    this.publish();
  }

  private publish(): void {
    this.views = [...this.entries.values()].map((pane) => pane.view);
    this.listeners.forEach((listener) => listener());
  }
}

function paneSocketPath(view: PaneView, size: PaneSize): string {
  const query = new URLSearchParams({ path: view.folder, run: view.run, cols: String(size.cols), rows: String(size.rows) });
  return `${projectPath(view.projectId, '/panes')}?${query.toString()}`;
}

function parseNotice(text: string): PaneNotice | null {
  let frame: unknown;
  try { frame = JSON.parse(text); } catch { return null; }
  if (typeof frame !== 'object' || frame === null || !('type' in frame) || typeof frame.type !== 'string') return null;
  return NOTICE_TYPES.has(frame.type) ? frame as PaneNotice : null;
}

function exitWords(code: number | null, signal: string | null): string {
  if (code !== null) return `${PANE_END_WORDS.sessionEnded} (exit ${code})`;
  if (signal !== null) return `${PANE_END_WORDS.sessionEnded} (${signal})`;
  return PANE_END_WORDS.sessionEnded;
}

function closeWords(code: number): string {
  if (code === PANE_CLOSE.ended) return PANE_END_WORDS.sessionEnded;
  if (code === PANE_CLOSE.daemonStopping) return PANE_END_WORDS.daemonStopped;
  if (code === PANE_CLOSE.projectGone) return PANE_END_WORDS.projectGone;
  return PANE_END_WORDS.connectionLost;
}
