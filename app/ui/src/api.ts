/**
 * The one door to the daemon. The token is read from the page URL once, at the composition root,
 * and kept in memory: fetches carry it as a bearer header, the event stream (which cannot set
 * headers) as `?token=`. Tests hand the hooks a fake `Api` instead.
 */
export type StreamLike = {
  addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void;
  readonly readyState: number;
  onopen: ((event: Event) => void) | null;
  onerror: ((event: Event) => void) | null;
  close(): void;
};

export type ApiResponse = { status: number; body: unknown };

export type HttpMethod = 'GET' | 'POST' | 'PUT';

export type Api = {
  request(path: string, method: HttpMethod, body: unknown): Promise<ApiResponse>;
  openStream(path: string): StreamLike;
};

export const STREAM_CLOSED = 2;

export function readToken(search: string): string | null {
  const token = new URLSearchParams(search).get('token');
  return token === null || token === '' ? null : token;
}

export function withToken(path: string, token: string | null): string {
  if (token === null) return path;
  const separator = path.includes('?') ? '&' : '?';
  return `${path}${separator}token=${encodeURIComponent(token)}`;
}

export function browserApi(token: string | null): Api {
  return {
    async request(path, method, body) {
      const headers: Record<string, string> = {};
      if (token !== null) headers.authorization = `Bearer ${token}`;
      if (body !== null) headers['content-type'] = 'application/json';
      const init: RequestInit = { method, headers };
      if (body !== null) init.body = JSON.stringify(body);
      try {
        const response = await fetch(path, init);
        const text = await response.text();
        return { status: response.status, body: text === '' ? null : parseJson(text) };
      } catch (error) {
        return { status: 0, body: { error: error instanceof Error ? error.message : 'network error' } };
      }
    },
    openStream(path) {
      return new EventSource(withToken(path, token));
    },
  };
}

function parseJson(text: string): unknown {
  try { return JSON.parse(text); } catch { return { error: text }; }
}

export function projectPath(projectId: string, rest: string): string {
  return `/api/projects/${encodeURIComponent(projectId)}${rest}`;
}

/** How long the page waits before it asks a daemon that did not answer again. */
export const DAEMON_RETRY_MS = 10000;
const HTTP_UNAUTHORIZED = 401;

/** What the page says when the daemon did not give it what it asked for, the same words on every screen. */
export function unreachableMessage(status: number): string {
  if (status === HTTP_UNAUTHORIZED) return 'Token needed: open the page with ?token=<token>';
  if (status === 0) return 'Daemon not reachable';
  return `The daemon answered ${status}`;
}
