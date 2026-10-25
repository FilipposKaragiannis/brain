import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { serveStatic } from '../src/static.ts';

const HTTP_OK = 200;
const HTTP_NOT_FOUND = 404;
const HTTP_SERVER_ERROR = 500;
const UNMATCHED = 'unmatched by static';
const NO_PERMISSIONS = 0o000;
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
  writeFileSync(join(dir, 'assets', 'locked.js'), SCRIPT);
  chmodSync(join(dir, 'assets', 'locked.js'), NO_PERMISSIONS);
  const server = createServer((request, response) => {
    if (serveStatic(request, response, dir)) return;
    response.writeHead(HTTP_NOT_FOUND);
    response.end(UNMATCHED);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  return {
    base: `http://127.0.0.1:${port}`,
    close: async () => { server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve())); rmSync(parent, { recursive: true, force: true }); },
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
    assert.equal(await response.text(), UNMATCHED, 'because a missing asset is the caller\'s to answer, not a page in disguise');
  } finally { await close(); }
});

test('EncodedTraversal_NeverLeavesDir', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/..%2fsecret.txt`);
    assert.equal(await response.text(), UNMATCHED, 'because a path outside dir is left to the caller, never served');
  } finally { await close(); }
});

test('PostRequest_NotMatched', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/index.html`, { method: 'POST' });
    assert.equal(await response.text(), UNMATCHED, 'because static files answer reads only, leaving writes to the API');
  } finally { await close(); }
});

test('ApiPathWithoutExtension_LeftToTheApiRoutes', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/api/projects/project/snapshot`);
    assert.equal(await response.text(), UNMATCHED, 'because the index fallback must never answer for an API route or its 401');
  } finally { await close(); }
});

test('HealthPath_LeftToTheDaemon', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/healthz`);
    assert.equal(await response.text(), UNMATCHED, 'because /healthz is the daemon\'s own answer');
  } finally { await close(); }
});

test('FileThatCannotBeRead_AnsweredWithoutCrashing', async () => {
  const { base, close } = await served();
  try {
    const response = await fetch(`${base}/assets/locked.js`);
    assert.equal(response.status, HTTP_SERVER_ERROR, 'because a read that fails after the stat is answered, not thrown into the daemon');
  } finally { await close(); }
});
