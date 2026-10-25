import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { serveStatic } from '../src/static.ts';

const HTTP_OK = 200;
const HTTP_TEAPOT = 418;
const INDEX_PAGE = '<!doctype html><title>console</title>';
const SCRIPT = 'console.log("ui")';
const SECRET = 'outside the served folder';

type Served = { base: string; close: () => Promise<void> };

async function served(): Promise<Served> {
  const parent = mkdtempSync(join(tmpdir(), 'static-'));
  const dir = join(parent, 'dist');
  mkdirSync(join(dir, 'assets'), { recursive: true });
  writeFileSync(join(dir, 'index.html'), INDEX_PAGE);
  writeFileSync(join(dir, 'assets', 'app.js'), SCRIPT);
  writeFileSync(join(parent, 'secret.txt'), SECRET);
  const server = createServer((request, response) => {
    if (serveStatic(request, response, dir)) return;
    response.writeHead(HTTP_TEAPOT);
    response.end('unmatched');
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    base: `http://127.0.0.1:${port}`,
    close: async () => { await new Promise<void>((resolve) => server.close(() => resolve())); rmSync(parent, { recursive: true, force: true }); },
  };
}

test('AssetUnderDir_ServedWithItsContentType', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/assets/app.js`);
    assert.equal(response.headers.get('content-type'), 'text/javascript; charset=utf-8', 'because a browser refuses a module script with the wrong type');
    assert.equal(await response.text(), SCRIPT, 'because the file under dir is what the path names');
  } finally { await close(); }
});

test('RootPath_ServesIndex', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/`);
    assert.equal(await response.text(), INDEX_PAGE, 'because the folder itself opens on its index page');
  } finally { await close(); }
});

test('PathWithoutExtension_FallsBackToIndex', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/gates/gh-7`);
    assert.equal(response.status, HTTP_OK, 'because the single page owns routes the server has no file for');
    assert.equal(await response.text(), INDEX_PAGE, 'because the fallback is the index page');
  } finally { await close(); }
});

test('MissingFileWithExtension_NotMatched', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/assets/missing.js`);
    assert.equal(response.status, HTTP_TEAPOT, 'because a missing asset is the caller\'s to answer, not a page in disguise');
  } finally { await close(); }
});

test('EncodedTraversal_NeverLeavesDir', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/..%2fsecret.txt`);
    assert.notEqual(await response.text(), SECRET, 'because nothing outside dir is ever served');
  } finally { await close(); }
});

test('PostRequest_NotMatched', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/index.html`, { method: 'POST' });
    assert.equal(response.status, HTTP_TEAPOT, 'because static files answer reads only, leaving writes to the API');
  } finally { await close(); }
});
