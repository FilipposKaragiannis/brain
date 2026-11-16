import type { PaneNotice, PaneSize, PaneTarget } from '../../daemon/src/paneProtocol.ts';
import { ACK_EVERY_BYTES, PANE_CLOSE, targetQuery } from '../../daemon/src/paneProtocol.ts';
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

export type PaneView = { key: string; projectId: string; target: PaneTarget; state: PaneState; command: string[]; ended: string | null };

/** What an ended pane says, by how it ended. An exit adds its code or signal to `sessionEnded`; a refusal says the daemon's words. */
export const PANE_END_WORDS = {
  sessionEnded: 'Session ended',
  daemonStopped: 'The daemon stopped',
  projectGone: 'The project is no longer watched',
  connectionLost: 'Connection to the daemon lost',
} as const;

/** A pane's terminal, its socket once open, the bytes it drew since its last ack, the size the daemon last heard and the size the terminal last fitted to. */
type Pane = { view: PaneView; terminal: TerminalLike; socket: SocketLike | null; drawnSinceAck: number; size: PaneSize | null; fitted: PaneSize | null };

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

  /** Adds an `opening` pane and returns its key; nothing reaches the daemon until `showAndConnect`. */
  open(projectId: string, target: PaneTarget): string {
    this.opened += 1;
    const key = `pane-${this.opened}`;
    const view: PaneView = { key, projectId, target, state: 'opening', command: [], ended: null };
    this.entries.set(key, { view, terminal: this.terminals(), socket: null, drawnSinceAck: 0, size: null, fitted: null });
    this.publish();
    return key;
  }

  /** Shows the pane's terminal in the container; the first time, fits it and opens the pane's socket at that size. */
  showAndConnect(key: string, container: HTMLElement): void {
    const pane = this.entries.get(key);
    if (pane === undefined) return;
    pane.terminal.showIn(container);
    if (pane.socket !== null) return;
    const size = pane.terminal.fit();
    const socket = this.api.openSocket(paneSocketPath(pane.view, size));
    pane.socket = socket;
    pane.size = size;
    pane.fitted = size;
    socket.onmessage = (event) => this.receive(pane, socket, event);
    socket.onclose = (event) => this.end(pane, closeWords(event.code));
    pane.terminal.onInput((bytes) => { if (pane.view.state === 'live') socket.send(bytes); });
  }

  /** Fits the pane's terminal again, and tells the daemon the size while the process runs and the size changed. */
  refit(key: string): void {
    const pane = this.entries.get(key);
    if (pane === undefined) return;
    pane.fitted = pane.terminal.fit();
    this.sendFittedSize(pane);
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
    const frame: unknown = event.data;
    if (frame instanceof ArrayBuffer) {
      const bytes = new Uint8Array(frame);
      pane.terminal.write(bytes, () => this.ackDrawn(pane, socket, bytes.byteLength));
      return;
    }
    if (typeof frame !== 'string') return;
    const notice = parseNotice(frame);
    if (notice === null) return;
    if (notice.type === 'started') { this.start(pane, notice.command); return; }
    if (notice.type === 'refused') { this.end(pane, notice.error); return; }
    this.end(pane, exitWords(notice.code, notice.signal));
  }

  /** Makes the pane live, then tells the daemon the size the terminal fitted to while it opened, if that differs. */
  private start(pane: Pane, command: string[]): void {
    this.change(pane, { ...pane.view, state: 'live', command });
    this.sendFittedSize(pane);
  }

  /** Sends the fitted size as a resize while the process runs and the daemon last heard another size. */
  private sendFittedSize(pane: Pane): void {
    const size = pane.fitted;
    if (size === null || pane.socket === null || pane.view.state !== 'live' || sameSize(pane.size, size)) return;
    pane.socket.send(JSON.stringify({ type: 'resize', cols: size.columns, rows: size.rows }));
    pane.size = size;
  }

  /** Counts the bytes the terminal drew and, once an ack is due, acks them to the daemon and starts the count again. */
  private ackDrawn(pane: Pane, socket: SocketLike, byteCount: number): void {
    const due = this.countDrawn(pane, byteCount);
    if (due === null) return;
    socket.send(JSON.stringify({ type: 'ack', bytes: due }));
    pane.drawnSinceAck = 0;
  }

  /** Adds the drawn bytes to the pane's count; returns the bytes to ack once `ACK_EVERY_BYTES` are drawn, null before or once the pane is closed or ended. */
  private countDrawn(pane: Pane, byteCount: number): number | null {
    if (this.entries.get(pane.view.key) !== pane || pane.view.state === 'ended') return null;
    pane.drawnSinceAck += byteCount;
    return pane.drawnSinceAck < ACK_EVERY_BYTES ? null : pane.drawnSinceAck;
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
  const query = new URLSearchParams({ ...targetQuery(view.target), cols: String(size.columns), rows: String(size.rows) });
  return `${projectPath(view.projectId, '/panes')}?${query.toString()}`;
}

function sameSize(last: PaneSize | null, size: PaneSize): boolean {
  return last !== null && last.columns === size.columns && last.rows === size.rows;
}

/** A text frame as a `PaneNotice` whose fields have the types its kind promises, or null for anything else. */
function parseNotice(text: string): PaneNotice | null {
  const fields = jsonObject(text);
  if (fields === null) return null;
  switch (fields.type) {
    case 'started': return startedNotice(fields);
    case 'refused': return refusedNotice(fields);
    case 'exit': return exitNotice(fields);
    default: return null;
  }
}

function jsonObject(text: string): Record<string, unknown> | null {
  let frame: unknown;
  try { frame = JSON.parse(text); } catch { return null; }
  return typeof frame === 'object' && frame !== null && !Array.isArray(frame) ? frame as Record<string, unknown> : null;
}

function startedNotice(fields: Record<string, unknown>): PaneNotice | null {
  const { pane, command, folder } = fields;
  if (typeof pane !== 'string' || typeof folder !== 'string' || !isTextList(command)) return null;
  return { type: 'started', pane, command, folder };
}

function refusedNotice(fields: Record<string, unknown>): PaneNotice | null {
  const { error } = fields;
  return typeof error === 'string' ? { type: 'refused', error } : null;
}

function exitNotice(fields: Record<string, unknown>): PaneNotice | null {
  const { code, signal } = fields;
  if (!isExitCode(code) || !isSignalName(signal)) return null;
  return { type: 'exit', code, signal };
}

function isExitCode(value: unknown): value is number | null {
  return value === null || Number.isInteger(value);
}

function isSignalName(value: unknown): value is string | null {
  return value === null || typeof value === 'string';
}

function isTextList(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((part) => typeof part === 'string');
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
