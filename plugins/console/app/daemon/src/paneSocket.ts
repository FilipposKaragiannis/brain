import { STATUS_CODES } from 'node:http';
import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocket, WebSocketServer } from 'ws';
import type { RawData } from 'ws';
import type { Logger } from './log.ts';
import { errorMessage } from './log.ts';
import { parsePaneRequest } from './panePlan.ts';
import type { PaneControl, PaneNotice } from './paneProtocol.ts';
import { INPUT_FRAME_LIMIT_BYTES, MAXIMUM_PANE_COLUMNS, MAXIMUM_PANE_ROWS, MINIMUM_PANE_COLUMNS, MINIMUM_PANE_ROWS, PANE_CLOSE } from './paneProtocol.ts';
import type { PaneLink, PaneSessions } from './panes.ts';
import { refuse } from './panes.ts';
import type { ProjectRegistry, ServedProject } from './registry.ts';

/** Whether a caller may open a pane at all: a refusal carries the HTTP status the upgrade is refused with. */
export type PaneAdmission = { ok: true } | { ok: false; status: number; error: string };

/** What the pane route needs from the server: the projects, the panes, and the server's own Host, Origin and token checks. */
export type PaneRoute = {
  registry: ProjectRegistry;
  panes: PaneSessions;
  admit(request: IncomingMessage, url: URL): PaneAdmission;
  log: Logger;
};

const PANE_PATH = /^\/api\/projects\/([^/]+)\/panes$/;
/** Only the path and the query of an upgrade are read, so any base parses them. */
const REQUEST_URL_BASE = 'http://localhost';
const HTTP_NOT_FOUND = 404;

/**
 * `GET /api/projects/<id>/panes` as a WebSocket, one per pane. A caller the server would refuse,
 * an unknown project or another path is refused before the handshake as plain HTTP; everything
 * after it (a bad request, a folder not listed, a pty that cannot start) is a `refused` frame and
 * close `refused`, because a page cannot read a failed handshake. A project that leaves the
 * registry, or whose id now names another root, has its panes closed `projectGone`; a text frame
 * that is not a control closes its pane `unknownFrame`.
 */
export function servePanes(server: Server, route: PaneRoute): void {
  const sockets = new WebSocketServer({ noServer: true, maxPayload: INPUT_FRAME_LIMIT_BYTES });
  const projects = new PaneProjects(route);
  const unsubscribe = route.registry.onChange(() => projects.endDeparted());
  server.once('close', unsubscribe);
  server.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => upgradePane(route, sockets, projects, { request, socket, head }));
}

/** One upgrade as the server hands it over: the request, its connection and the bytes already read past the headers. */
type Upgrade = { request: IncomingMessage; socket: Duplex; head: Buffer };

/** What starting a pane on a completed handshake needs besides the socket. */
type PaneOpening = { route: PaneRoute; projects: PaneProjects; served: ServedProject; query: URLSearchParams };

/**
 * Refuses an upgrade the server would refuse, or hands it to `ws`. Node drops its own error
 * listener before it emits `upgrade`, so a peer that resets a refused connection would throw from
 * the socket; until `ws` takes the socket over, an error drops it and is logged.
 */
function upgradePane(route: PaneRoute, sockets: WebSocketServer, projects: PaneProjects, upgrade: Upgrade): void {
  const { request, socket, head } = upgrade;
  const dropOnError = (error: Error): void => {
    route.log.warn('pane.upgrade', { error: error.message });
    socket.destroy();
  };
  socket.on('error', dropOnError);
  const url = new URL(request.url ?? '/', REQUEST_URL_BASE);
  const admission = route.admit(request, url);
  if (!admission.ok) { refuseUpgrade(socket, admission.status, admission.error); return; }
  const served = paneProject(route.registry, url.pathname);
  if (served === undefined) { refuseUpgrade(socket, HTTP_NOT_FOUND, 'not found'); return; }
  sockets.handleUpgrade(request, socket, head, (connection) => {
    socket.off('error', dropOnError);
    openPane({ route, projects, served, query: url.searchParams }, connection);
  });
}

/** The projects that opened a pane, so a project that leaves the registry, or whose id now names another root, has its panes ended. */
class PaneProjects {
  private readonly route: PaneRoute;
  private readonly served = new Map<string, ServedProject>();

  constructor(route: PaneRoute) {
    this.route = route;
  }

  add(served: ServedProject): void {
    this.served.set(served.monitor.project.id, served);
  }

  /** Ends the panes of every project the registry no longer serves as it did. */
  endDeparted(): void {
    for (const [id, served] of [...this.served]) {
      if (this.route.registry.get(id) === served) continue;
      this.served.delete(id);
      this.route.panes.endProject(id);
    }
  }
}

/** The project a pane path names, or undefined for another path, an id that does not decode, or a project not served. */
function paneProject(registry: ProjectRegistry, pathname: string): ServedProject | undefined {
  const match = PANE_PATH.exec(pathname);
  if (match === null) return undefined;
  const id = decodedSegment(match[1]!);
  return id === null ? undefined : registry.get(id);
}

/** A path segment decoded, or null when its percent escapes are not UTF-8 (`decodeURIComponent` throws on those). */
function decodedSegment(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

/**
 * Starts the pane a handshake asked for on its socket, or refuses it there when the query is not a
 * pane request. A pane that throws while it starts is refused with the reason, never a crash.
 */
function openPane(opening: PaneOpening, connection: WebSocket): void {
  const { route, projects, served } = opening;
  const link = socketLink(connection, route.log);
  const parsed = parsePaneRequest(opening.query);
  if (!parsed.ok) { refuse(link, parsed.error); return; }
  const projectId = served.monitor.project.id;
  projects.add(served);
  try {
    route.panes.open(projectId, parsed.request, served.monitor.paneFacts(), link);
  } catch (error) {
    route.log.warn('pane.refused', { project: projectId, error: errorMessage(error) });
    refuse(link, `the pane did not start: ${errorMessage(error)}`);
  }
}

/** Answers an upgrade with a plain HTTP error and drops the connection once it is written. */
function refuseUpgrade(socket: Duplex, status: number, error: string): void {
  const body = JSON.stringify({ error });
  socket.once('finish', () => socket.destroy());
  socket.end(`HTTP/1.1 ${status} ${STATUS_CODES[status] ?? ''}\r\nconnection: close\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

/** A pane's link over its socket: binary frames are terminal bytes, text frames JSON. */
function socketLink(connection: WebSocket, log: Logger): PaneLink {
  connection.on('error', (error) => log.warn('pane.socket', { error: error.message }));
  const open = (): boolean => connection.readyState === WebSocket.OPEN;
  return {
    output: (bytes) => { if (open()) connection.send(bytes, { binary: true }); },
    tell: (notice: PaneNotice) => { if (open()) connection.send(JSON.stringify(notice)); },
    end: (code) => { connection.close(code); },
    onInput: (listener) => {
      connection.on('message', (rawFrame: RawData, isBinary: boolean) => { if (isBinary) listener(frameBytes(rawFrame)); });
    },
    onControl: (listener) => { connection.on('message', controlHandler(connection, listener)); },
    onGone: (listener) => {
      if (connection.readyState === WebSocket.CLOSED) { listener(); return; }
      connection.once('close', () => listener());
    },
    queuedBytes: () => connection.bufferedAmount,
  };
}

/** Hands the listener each text frame that is a control, and closes the pane `unknownFrame` on any other text frame. */
function controlHandler(connection: WebSocket, listener: (control: PaneControl) => void): (rawFrame: RawData, isBinary: boolean) => void {
  return (rawFrame, isBinary) => {
    if (isBinary) return;
    const control = parseControl(frameBytes(rawFrame).toString());
    if (control === null) { connection.close(PANE_CLOSE.unknownFrame); return; }
    listener(control);
  };
}

function frameBytes(rawFrame: RawData): Buffer {
  if (Array.isArray(rawFrame)) return Buffer.concat(rawFrame);
  if (rawFrame instanceof ArrayBuffer) return Buffer.from(rawFrame);
  return rawFrame;
}

/** A text frame as a `PaneControl`, or null for anything else. */
function parseControl(text: string): PaneControl | null {
  let frame: unknown;
  try { frame = JSON.parse(text); } catch { return null; }
  if (typeof frame !== 'object' || frame === null) return null;
  const fields = frame as Record<string, unknown>;
  if (fields.type === 'resize') return resizeControl(fields.cols, fields.rows);
  if (fields.type === 'ack' && isWholeNumber(fields.bytes, 0, Number.MAX_SAFE_INTEGER)) return { type: 'ack', bytes: fields.bytes };
  return null;
}

function resizeControl(columns: unknown, rows: unknown): PaneControl | null {
  if (!isWholeNumber(columns, MINIMUM_PANE_COLUMNS, MAXIMUM_PANE_COLUMNS) || !isWholeNumber(rows, MINIMUM_PANE_ROWS, MAXIMUM_PANE_ROWS)) return null;
  return { type: 'resize', cols: columns, rows };
}

function isWholeNumber(value: unknown, minimum: number, maximum: number): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= minimum && value <= maximum;
}
