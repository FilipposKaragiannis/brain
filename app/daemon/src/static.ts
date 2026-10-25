import { createReadStream, statSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { extname, join, resolve, sep } from 'node:path';

const HTTP_OK = 200;
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
 * `dir`, a method other than GET or HEAD), leaving the response untouched for the caller.
 */
export function serveStatic(request: IncomingMessage, response: ServerResponse, dir: string): boolean {
  if (request.method !== 'GET' && request.method !== 'HEAD') return false;
  const pathname = decodedPathname(request.url ?? '/');
  if (pathname === null) return false;
  const root = resolve(dir);
  const target = resolve(join(root, pathname));
  if (target !== root && !target.startsWith(root + sep)) return false;
  const file = fileAt(target) ?? fileAt(join(target, INDEX)) ?? (extname(pathname) === '' ? fileAt(join(root, INDEX)) : null);
  if (file === null) return false;
  response.writeHead(HTTP_OK, {
    'content-type': CONTENT_TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream',
    'content-length': String(statSync(file).size),
    'cache-control': extname(file) === '.html' ? 'no-cache' : 'public, max-age=3600',
  });
  if (request.method === 'HEAD') { response.end(); return true; }
  createReadStream(file).pipe(response);
  return true;
}

function decodedPathname(url: string): string | null {
  try {
    const pathname = decodeURIComponent(new URL(url, 'http://localhost').pathname);
    return pathname.includes('\0') ? null : pathname;
  } catch {
    return null;
  }
}

function fileAt(path: string): string | null {
  try {
    return statSync(path).isFile() ? path : null;
  } catch {
    return null;
  }
}
