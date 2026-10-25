import { createServer } from 'node:http';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import type { Logger } from './log.ts';
import type { ProjectMonitor } from './project.ts';
import type { SourceName } from './snapshot.ts';

export type ServerOptions = { host: string; port: number; token: string | null; log: Logger };

const HEARTBEAT_MS = 15000;
const SOURCES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board', 'pulls'];
const HTTP_OK = 200;
const HTTP_NO_CONTENT = 204;
const HTTP_ACCEPTED = 202;
const HTTP_UNAUTHORIZED = 401;
const HTTP_NOT_FOUND = 404;
const HTTP_METHOD_NOT_ALLOWED = 405;

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}

function authorized(request: IncomingMessage, url: URL, token: string | null): boolean {
  if (token === null) return true;
  const header = request.headers.authorization ?? '';
  return header === `Bearer ${token}` || url.searchParams.get('token') === token;
}

/**
 * The read side of the daemon: snapshots over HTTP and a server-sent event stream per project.
 * Actions (running flow scripts) come in the next slice and will share this server.
 */
export function createConsoleServer(monitors: ProjectMonitor[], options: ServerOptions): Server {
  const byId = new Map(monitors.map((monitor) => [monitor.project.id, monitor]));
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? '/', `http://${options.host}:${options.port}`);
    response.setHeader('access-control-allow-origin', '*');
    response.setHeader('access-control-allow-headers', 'authorization, content-type');
    if (request.method === 'OPTIONS') { response.writeHead(HTTP_NO_CONTENT); response.end(); return; }
    if (!authorized(request, url, options.token)) { sendJson(response, HTTP_UNAUTHORIZED, { error: 'token required' }); return; }
    if (url.pathname === '/healthz') { sendJson(response, HTTP_OK, { ok: true, projects: [...byId.keys()] }); return; }
    if (url.pathname === '/api/projects') {
      sendJson(response, HTTP_OK, monitors.map((monitor) => ({ ...monitor.project, counts: monitor.snapshot?.counts ?? null, takenAt: monitor.snapshot?.takenAt ?? null })));
      return;
    }
    const match = /^\/api\/projects\/([^/]+)\/(snapshot|events|refresh)$/.exec(url.pathname);
    const monitor = match === null ? undefined : byId.get(decodeURIComponent(match[1]!));
    if (match === null || monitor === undefined) { sendJson(response, HTTP_NOT_FOUND, { error: 'not found' }); return; }
    const route = match[2];
    if (route === 'snapshot') { sendJson(response, HTTP_OK, monitor.snapshot); return; }
    if (route === 'refresh') {
      if (request.method !== 'POST') { sendJson(response, HTTP_METHOD_NOT_ALLOWED, { error: 'POST only' }); return; }
      const wanted = url.searchParams.get('source');
      const sources = SOURCES.filter((source) => wanted === null || source === wanted);
      void Promise.all(sources.map((source) => monitor.refresh(source)));
      sendJson(response, HTTP_ACCEPTED, { refreshing: sources });
      return;
    }
    streamEvents(monitor, request, response, options.log);
  });
  return server;
}

function streamEvents(monitor: ProjectMonitor, request: IncomingMessage, response: ServerResponse, log: Logger): void {
  response.writeHead(HTTP_OK, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
  const send = (event: string, data: unknown): void => { response.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); };
  if (monitor.snapshot !== null) send('snapshot', monitor.snapshot);
  const unsubscribe = monitor.onChange((snapshot) => send('snapshot', snapshot));
  const heartbeat = setInterval(() => { response.write(': ping\n\n'); }, HEARTBEAT_MS);
  log.info('stream.open', { project: monitor.project.id });
  request.on('close', () => { unsubscribe(); clearInterval(heartbeat); log.info('stream.close', { project: monitor.project.id }); });
}
