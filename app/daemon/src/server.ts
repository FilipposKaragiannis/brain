import { timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import type { ActionRunner } from './actions.ts';
import type { Logger } from './log.ts';
import type { ProjectMonitor } from './project.ts';
import { filterEvents } from './events.ts';
import { serveStatic } from './static.ts';
import { EVENTS_KEPT, SOURCE_NAMES } from './snapshot.ts';

/** `staticDir` is the built UI, served at `/` without a token: the page carries the token itself, the assets are public code. */
export type ServerOptions = { host: string; port: number; token: string; staticDir: string | null; log: Logger };

/** One project as the server sees it: its live picture and the thing that runs its actions. */
export type ServedProject = { monitor: ProjectMonitor; actions: ActionRunner };

const HEARTBEAT_MS = 15000;
const BODY_LIMIT_BYTES = 64 * 1024;
const HTTP_OK = 200;
const HTTP_NO_CONTENT = 204;
const HTTP_ACCEPTED = 202;
const HTTP_BAD_REQUEST = 400;
const HTTP_UNAUTHORIZED = 401;
const HTTP_FORBIDDEN = 403;
const HTTP_NOT_FOUND = 404;
const HTTP_METHOD_NOT_ALLOWED = 405;
const HTTP_TOO_LARGE = 413;
const HTTP_UNSUPPORTED_MEDIA = 415;
/** The hosts a browser may name for this server: its own loopback address and localhost. */
const LOCAL_HOSTS = ['127.0.0.1', 'localhost', '[::1]'];

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}

function sameSecret(given: string, token: string): boolean {
  const a = Buffer.from(given);
  const b = Buffer.from(token);
  return a.length === b.length && timingSafeEqual(a, b);
}

function authorized(request: IncomingMessage, url: URL, token: string): boolean {
  const header = request.headers.authorization ?? '';
  const bearer = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : '';
  return sameSecret(bearer, token) || sameSecret(url.searchParams.get('token') ?? '', token);
}

/** The hostname of a Host header or an Origin, without the port. */
function hostnameOf(value: string): string | null {
  try { return new URL(value.includes('://') ? value : `http://${value}`).hostname; } catch { return null; }
}

/**
 * A browser must only reach this server as itself: the Host header names a loopback address (so
 * a DNS rebinding attack, whose Host is the attacker's name, is refused) and an Origin, when a
 * page sends one, is a loopback page too (so a page on another site cannot post an action).
 */
function localCaller(request: IncomingMessage): { ok: true; origin: string | null } | { ok: false; error: string } {
  const host = hostnameOf(request.headers.host ?? '');
  if (host === null || !LOCAL_HOSTS.includes(host.startsWith('[') ? host : host.replace(/^\[|\]$/g, ''))) return { ok: false, error: 'host must be 127.0.0.1 or localhost' };
  const origin = request.headers.origin ?? null;
  if (origin === null) return { ok: true, origin: null };
  const originHost = hostnameOf(origin);
  if (originHost === null || !LOCAL_HOSTS.includes(originHost)) return { ok: false, error: 'origin must be a local page' };
  return { ok: true, origin };
}

function readBody(request: IncomingMessage): Promise<{ ok: true; body: unknown } | { ok: false; status: number; error: string }> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > BODY_LIMIT_BYTES) { resolve({ ok: false, status: HTTP_TOO_LARGE, error: 'body too large' }); request.removeAllListeners('data'); request.resume(); return; }
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
 * The daemon's HTTP face: the built UI at `/`, snapshots and actions over JSON, and one
 * server-sent event stream per project that carries both `snapshot` and `action` events.
 */
export function createConsoleServer(projects: ServedProject[], options: ServerOptions): Server {
  const byId = new Map(projects.map((served) => [served.monitor.project.id, served]));
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? '/', `http://${options.host}:${options.port}`);
    const caller = localCaller(request);
    if (!caller.ok) { sendJson(response, HTTP_FORBIDDEN, { error: caller.error }); return; }
    if (caller.origin !== null) {
      response.setHeader('access-control-allow-origin', caller.origin);
      response.setHeader('access-control-allow-headers', 'authorization, content-type');
      response.setHeader('access-control-allow-methods', 'GET, POST, OPTIONS');
      response.setHeader('vary', 'origin');
    }
    if (request.method === 'OPTIONS') { response.writeHead(HTTP_NO_CONTENT); response.end(); return; }
    if (options.staticDir !== null && serveStatic(request, response, options.staticDir)) return;
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
    if (wantsEventList(request, url)) { eventList(served.monitor, response, url); return; }
    streamEvents(served, request, response, options.log);
  });
  return server;
}

/**
 * `/events` is the live stream, unless the caller asks for the kept events as JSON: with `item`
 * or `limit` in the query, or `Accept: application/json`. An EventSource never sends either.
 */
function wantsEventList(request: IncomingMessage, url: URL): boolean {
  return url.searchParams.has('item') || url.searchParams.has('limit') || (request.headers.accept ?? '').includes('application/json');
}

const LIMIT = /^[1-9][0-9]*$/;

function eventList(monitor: ProjectMonitor, response: ServerResponse, url: URL): void {
  const item = url.searchParams.get('item') || null;
  const limitText = url.searchParams.get('limit') ?? String(EVENTS_KEPT);
  if (!LIMIT.test(limitText)) { sendJson(response, HTTP_BAD_REQUEST, { error: 'limit must be a positive whole number' }); return; }
  const limit = Math.min(Number(limitText), EVENTS_KEPT);
  sendJson(response, HTTP_OK, { ...filterEvents(monitor.snapshot?.events ?? [], item, limit), kept: EVENTS_KEPT });
}

function refresh(monitor: ProjectMonitor, request: IncomingMessage, response: ServerResponse, url: URL): void {
  if (request.method !== 'POST') { sendJson(response, HTTP_METHOD_NOT_ALLOWED, { error: 'POST only' }); return; }
  const wanted = url.searchParams.get('source');
  const sources = SOURCE_NAMES.filter((source) => wanted === null || source === wanted);
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
  if (!(request.headers['content-type'] ?? '').startsWith('application/json')) { sendJson(response, HTTP_UNSUPPORTED_MEDIA, { error: 'send application/json' }); return; }
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
