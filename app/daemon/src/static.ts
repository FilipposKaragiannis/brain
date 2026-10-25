import { createReadStream, statSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { extname, join, resolve, sep } from 'node:path';

const HTTP_OK = 200;
const HTTP_NOT_FOUND = 404;
const HTTP_SERVER_ERROR = 500;
/** Paths the daemon's own routes answer; the index fallback must never shadow them. */
const API_PATHS = /^\/(?:api|healthz)(?:\/|$)/;
const INDEX = 'index.html';

const CONTENT_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
};

/**
 * Serves the built UI. A path that names a file under `dir` gets that file with its content
 * type; a path with no extension gets `index.html`, so the single page owns its own routes.
 * Returns false when nothing matched (a missing file with an extension, a path that escapes
 * `dir`, an `/api/` or `/healthz` path, a method other than GET or HEAD), leaving the response
 * untouched for the caller. A file that vanishes between the stat and the read (a rebuild of
 * dist) is answered 404, never thrown.
 */
export function serveStatic(request: IncomingMessage, response: ServerResponse, dir: string): boolean {
  if (request.method !== 'GET' && request.method !== 'HEAD') return false;
  const pathname = decodedPathname(request.url ?? '/');
  if (pathname === null || API_PATHS.test(pathname)) return false;
  const root = resolve(dir);
  const target = resolve(join(root, pathname));
  if (target !== root && !target.startsWith(root + sep)) return false;
  const file = fileAt(target) ?? fileAt(join(target, INDEX)) ?? (extname(pathname) === '' ? fileAt(join(root, INDEX)) : null);
  if (file === null) return false;
  const headers = {
    'content-type': CONTENT_TYPES[extname(file.path).toLowerCase()] ?? 'application/octet-stream',
    'content-length': String(file.size),
    'cache-control': extname(file.path) === '.html' ? 'no-cache' : 'public, max-age=3600',
  };
  if (request.method === 'HEAD') { response.writeHead(HTTP_OK, headers); response.end(); return true; }
  const stream = createReadStream(file.path);
  stream.on('error', (error: NodeJS.ErrnoException) => failRead(response, error));
  stream.on('open', () => { response.writeHead(HTTP_OK, headers); stream.pipe(response); });
  return true;
}

function failRead(response: ServerResponse, error: NodeJS.ErrnoException): void {
  if (response.headersSent) { response.destroy(); return; }
  response.writeHead(error.code === 'ENOENT' ? HTTP_NOT_FOUND : HTTP_SERVER_ERROR);
  response.end();
}

function decodedPathname(url: string): string | null {
  try {
    const pathname = decodeURIComponent(new URL(url, 'http://localhost').pathname);
    return pathname.includes('\0') ? null : pathname;
  } catch {
    return null;
  }
}

type FoundFile = { path: string; size: number };

function fileAt(path: string): FoundFile | null {
  try {
    const stats = statSync(path);
    return stats.isFile() ? { path, size: stats.size } : null;
  } catch {
    return null;
  }
}
