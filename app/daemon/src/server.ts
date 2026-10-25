import { createServer } from 'node:http';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import type { ActionRunner } from './actions.ts';
import type { Logger } from './log.ts';
import type { ProjectMonitor } from './project.ts';
import type { SourceName } from './snapshot.ts';

export type ServerOptions = { host: string; port: number; token: string | null; log: Logger };

/** One project as the server sees it: its live picture and the thing that runs its actions. */
export type ServedProject = { monitor: ProjectMonitor; actions: ActionRunner };

const HEARTBEAT_MS = 15000;
const SOURCES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board'];
const BODY_LIMIT_BYTES = 64 * 1024;
const HTTP_OK = 200;
const HTTP_NO_CONTENT = 204;
const HTTP_ACCEPTED = 202;
const HTTP_BAD_REQUEST = 400;
const HTTP_UNAUTHORIZED = 401;
const HTTP_NOT_FOUND = 404;
const HTTP_METHOD_NOT_ALLOWED = 405;
const HTTP_TOO_LARGE = 413;

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}

function authorized(request: IncomingMessage, url: URL, token: string | null): boolean {
  if (token === null) return true;
  const header = request.headers.authorization ?? '';
  return header === `Bearer ${token}` || url.searchParams.get('token') === token;
}

function readBody(request: IncomingMessage): Promise<{ ok: true; body: unknown } | { ok: false; status: number; error: string }> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > BODY_LIMIT_BYTES) { resolve({ ok: false, status: HTTP_TOO_LARGE, error: 'body too large' }); request.destroy(); return; }
      chunks.push(chunk);
    });
    request.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (text === '') { resolve({ ok: true, body: {} }); return; }
      try { resolve({ ok: true, body: JSON.parse(text) }); } catch { resolve({ ok: false, status: HTTP_BAD_REQUEST, error: 'body is not JSON' }); }
    });
    request.on('error', () => resolve({ ok: false, status: HTTP_BAD_REQUEST, error: 'body not read' }));
  });
}

/**
 * The daemon's HTTP face: snapshots and actions over JSON, and one server-sent event stream per
 * project that carries both `snapshot` and `action` events.
 */
export function createConsoleServer(projects: ServedProject[], options: ServerOptions): Server {
  const byId = new Map(projects.map((served) => [served.monitor.project.id, served]));
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? '/', `http://${options.host}:${options.port}`);
    response.setHeader('access-control-allow-origin', '*');
    response.setHeader('access-control-allow-headers', 'authorization, content-type');
    response.setHeader('access-control-allow-methods', 'GET, POST, OPTIONS');
    if (request.method === 'OPTIONS') { response.writeHead(HTTP_NO_CONTENT); response.end(); return; }
    if (!authorized(request, url, options.token)) { sendJson(response, HTTP_UNAUTHORIZED, { error: 'token required' }); return; }
    if (url.pathname === '/healthz') { sendJson(response, HTTP_OK, { ok: true, projects: [...byId.keys()] }); return; }
    if (url.pathname === '/api/projects') {
      sendJson(response, HTTP_OK, projects.map(({ monitor }) => ({ ...monitor.project, counts: monitor.snapshot?.counts ?? null, takenAt: monitor.snapshot?.takenAt ?? null })));
      return;
    }
    const match = /^\/api\/projects\/([^/]+)\/(snapshot|events|refresh|actions)(?:\/([^/]+))?$/.exec(url.pathname);
    const served = match === null ? undefined : byId.get(decodeURIComponent(match[1]!));
    if (match === null || served === undefined) { sendJson(response, HTTP_NOT_FOUND, { error: 'not found' }); return; }
    const route = match[2];
    const actionId = match[3];
    if (actionId !== undefined && route !== 'actions') { sendJson(response, HTTP_NOT_FOUND, { error: 'not found' }); return; }
    if (route === 'snapshot') { sendJson(response, HTTP_OK, served.monitor.snapshot); return; }
    if (route === 'refresh') { refresh(served.monitor, request, response, url); return; }
    if (route === 'actions') { void actions(served.actions, request, response, actionId); return; }
    streamEvents(served, request, response, options.log);
  });
  return server;
}

function refresh(monitor: ProjectMonitor, request: IncomingMessage, response: ServerResponse, url: URL): void {
  if (request.method !== 'POST') { sendJson(response, HTTP_METHOD_NOT_ALLOWED, { error: 'POST only' }); return; }
  const wanted = url.searchParams.get('source');
  const sources = SOURCES.filter((source) => wanted === null || source === wanted);
  void Promise.all(sources.map((source) => monitor.refresh(source)));
  sendJson(response, HTTP_ACCEPTED, { refreshing: sources });
}

async function actions(runner: ActionRunner, request: IncomingMessage, response: ServerResponse, actionId: string | undefined): Promise<void> {
  if (request.method === 'GET' && actionId !== undefined) {
    const record = runner.get(actionId);
    if (record === null) sendJson(response, HTTP_NOT_FOUND, { error: 'no such action' }); else sendJson(response, HTTP_OK, record);
    return;
  }
  if (request.method === 'GET') { sendJson(response, HTTP_OK, { actions: runner.list() }); return; }
  if (request.method !== 'POST' || actionId !== undefined) { sendJson(response, HTTP_METHOD_NOT_ALLOWED, { error: 'GET or POST' }); return; }
  const read = await readBody(request);
  if (!read.ok) { sendJson(response, read.status, { error: read.error }); return; }
  const body = (typeof read.body === 'object' && read.body !== null ? read.body : {}) as { kind?: unknown; args?: unknown };
  const outcome = runner.request(body.kind, body.args);
  sendJson(response, outcome.status, outcome.body);
}

function streamEvents(served: ServedProject, request: IncomingMessage, response: ServerResponse, log: Logger): void {
  const { monitor, actions: runner } = served;
  response.writeHead(HTTP_OK, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
  const send = (event: string, data: unknown): void => { response.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); };
  if (monitor.snapshot !== null) send('snapshot', monitor.snapshot);
  const unsubscribeSnapshots = monitor.onChange((snapshot) => send('snapshot', snapshot));
  const unsubscribeActions = runner.onChange((record) => send('action', record));
  const heartbeat = setInterval(() => { response.write(': ping\n\n'); }, HEARTBEAT_MS);
  log.info('stream.open', { project: monitor.project.id });
  request.on('close', () => { unsubscribeSnapshots(); unsubscribeActions(); clearInterval(heartbeat); log.info('stream.close', { project: monitor.project.id }); });
}
