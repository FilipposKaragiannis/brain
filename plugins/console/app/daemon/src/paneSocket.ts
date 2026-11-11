import { STATUS_CODES } from 'node:http';
import type { IncomingMessage, Server } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocket, WebSocketServer } from 'ws';
import type { RawData } from 'ws';
import type { Logger } from './log.ts';
import { parsePaneRequest } from './panePlan.ts';
import type { PaneControl, PaneNotice } from './paneProtocol.ts';
import { INPUT_FRAME_LIMIT_BYTES, MAX_PANE_COLUMNS, MAX_PANE_ROWS, MIN_PANE_COLUMNS, MIN_PANE_ROWS, PANE_CLOSE } from './paneProtocol.ts';
import type { PaneLink, PaneSessions } from './panes.ts';
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
  server.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
    const url = new URL(request.url ?? '/', REQUEST_URL_BASE);
    const admission = route.admit(request, url);
    if (!admission.ok) { refuseUpgrade(socket, admission.status, admission.error); return; }
    const served = paneProject(route.registry, url.pathname);
    if (served === undefined) { refuseUpgrade(socket, HTTP_NOT_FOUND, 'not found'); return; }
    sockets.handleUpgrade(request, socket, head, (connection) => openPane(route, projects, served, url.searchParams, connection));
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

/** Starts the pane a handshake asked for on its socket, or refuses it there when the query is not a pane request. */
function openPane(route: PaneRoute, projects: PaneProjects, served: ServedProject, query: URLSearchParams, connection: WebSocket): void {
  const link = socketLink(connection, route.log);
  const parsed = parsePaneRequest(query);
  if (!parsed.ok) { link.tell({ type: 'refused', error: parsed.error }); link.end(PANE_CLOSE.refused); return; }
  const { project } = served.monitor;
  projects.add(served);
  route.panes.open({ id: project.id, root: project.root }, parsed.request, served.monitor.paneFacts(), link);
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
      connection.on('message', (data: RawData, isBinary: boolean) => { if (isBinary) listener(frameBytes(data)); });
    },
    onControl: (listener) => {
      connection.on('message', (data: RawData, isBinary: boolean) => {
        if (isBinary) return;
        const control = parseControl(frameBytes(data).toString());
        if (control === null) { connection.close(PANE_CLOSE.unknownFrame); return; }
        listener(control);
      });
    },
    onGone: (listener) => {
      if (connection.readyState === WebSocket.CLOSED) { listener(); return; }
      connection.once('close', () => listener());
    },
    queuedBytes: () => connection.bufferedAmount,
  };
}

function frameBytes(data: RawData): Buffer {
  if (Array.isArray(data)) return Buffer.concat(data);
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  return data;
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
  if (!isWholeNumber(columns, MIN_PANE_COLUMNS, MAX_PANE_COLUMNS) || !isWholeNumber(rows, MIN_PANE_ROWS, MAX_PANE_ROWS)) return null;
  return { type: 'resize', cols: columns, rows };
}

function isWholeNumber(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
}
