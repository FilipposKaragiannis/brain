import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rm } from 'node:fs/promises';
import { request } from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { ActionRunner, realScheduler } from '../src/actions.ts';
import { silentLogger } from '../src/log.ts';
import { ProjectMonitor } from '../src/project.ts';
import { createConsoleServer } from '../src/server.ts';
import type { Snapshot } from '../src/snapshot.ts';
import { FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';
import { plainSpawner } from './fakeSpawner.ts';
import type { FakeProcess } from './fakeSpawner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LONG_CADENCE = { filesMs: 600000, gitMs: 600000, processesMs: 600000, jobsMs: 600000, boardMs: 600000, pullsMs: 600000 };

async function started(): Promise<{ monitor: ProjectMonitor; processes: FakeProcess[]; base: string; close: () => Promise<void> }> {
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE });
  const { spawner, processes } = plainSpawner();
  const stateDir = path.join(os.tmpdir(), `console-server-${process.pid}`);
  const actions = new ActionRunner({ projectId: 'project', context: () => monitor.actionContext(), spawner, scheduler: realScheduler, clock: () => NOW, log: silentLogger, stateDir, onRefresh: () => {} });
  const server = createConsoleServer([{ monitor, actions }], { host: '127.0.0.1', port: 0, token: 'tok', log: silentLogger });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  await monitor.start();
  await monitor.refresh('board');
  const { port } = server.address() as AddressInfo;
  return { monitor, processes, base: `http://127.0.0.1:${port}`, close: async () => { monitor.stop(); await new Promise<void>((resolve) => server.close(() => resolve())); await rm(stateDir, { recursive: true, force: true }); } };
}

test('Snapshot_ServedWithToken', async () => {
  const { base, close } = await started();
  try {
    const response = await fetch(`${base}/api/projects/project/snapshot`, { headers: { authorization: 'Bearer tok' } });
    const picture = (await response.json()) as Snapshot;
    assert.equal(picture.schema, 1, 'because readers pin the schema version');
    assert.equal(picture.counts.running, 1, 'because the fake process list has one agent in a pool worktree');
    assert.equal(picture.sources.board.ok, true, 'because the board was read');
    assert.equal(picture.items.length, 7, 'because the fake board lists six items and the gh#5 claim adds one the board never saw');
  } finally { await close(); }
});

test('Snapshot_WithoutToken_Refused', async () => {
  const { base, close } = await started();
  try {
    assert.equal((await fetch(`${base}/api/projects/project/snapshot`)).status, 401, 'because a configured token guards every route');
  } finally { await close(); }
});

test('EventStream_SendsCurrentSnapshotFirst', async () => {
  const { base, close } = await started();
  try {
    const controller = new AbortController();
    const response = await fetch(`${base}/api/projects/project/events?token=tok`, { signal: controller.signal });
    const reader = response.body!.getReader();
    const { value } = await reader.read();
    controller.abort();
    const text = new TextDecoder().decode(value);
    assert.ok(text.startsWith('event: snapshot\ndata: {"schema":1'), 'because a new listener needs the picture before any change');
  } finally { await close(); }
});

test('Refresh_ReRunsOneSource', async () => {
  const { base, monitor, close } = await started();
  try {
    const response = await fetch(`${base}/api/projects/project/refresh?source=processes&token=tok`, { method: 'POST' });
    assert.deepEqual(await response.json(), { refreshing: ['processes'] }, 'because the caller asked for one source');
    assert.equal(monitor.snapshot?.project.pluginVersion, '9.9.9', 'because the snapshot survives a refresh');
  } finally { await close(); }
});

test('Actions_PostedRunAndStreamOnTheEventChannel', async () => {
  const { base, processes, close } = await started();
  try {
    const stream = await fetch(`${base}/api/projects/project/events?token=tok`, { signal: AbortSignal.timeout(5000) });
    const reader = stream.body!.getReader();
    const posted = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: { authorization: 'Bearer tok', 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'gate.clear', args: { item: 'gh#7', message: 'go' } }) });
    assert.equal(posted.status, 202, 'because the action is accepted');
    const { action } = (await posted.json()) as { action: { id: string; command: string[] } };
    assert.equal(action.command[1], '/fake/plugins/flow/9.9.9/scripts/gate.sh', 'because the plugin the project resolves is used');
    processes[0]!.stdout.write('cleared\n');
    processes[0]!.exit(0, null);
    let text = '';
    const actionDone = /event: action\ndata: [^\n]*"state":"done"/;
    while (!actionDone.test(text)) text += new TextDecoder().decode((await reader.read()).value);
    assert.match(text, /event: action/, 'because actions travel on the same stream as snapshots');
    const detail = await fetch(`${base}/api/projects/project/actions/${action.id}`, { headers: { authorization: 'Bearer tok' } });
    assert.equal(((await detail.json()) as { output: string }).output, 'cleared\n', 'because the detail route has the full output');
    const listed = await fetch(`${base}/api/projects/project/actions`, { headers: { authorization: 'Bearer tok' } });
    assert.equal(((await listed.json()) as { actions: unknown[] }).actions.length, 1, 'because one action ran');
    await reader.cancel();
  } finally { await close(); }
});

const JSON_HEADERS = { authorization: 'Bearer tok', 'content-type': 'application/json' };

test('Actions_BadKind_BadRequest', async () => {
  const { base, close } = await started();
  try {
    const posted = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: JSON_HEADERS, body: JSON.stringify({ kind: 'shell', args: {} }) });
    assert.equal(posted.status, 400, 'because only allow-listed kinds run');
  } finally { await close(); }
});

test('Actions_BodyNotJson_BadRequest', async () => {
  const { base, close } = await started();
  try {
    const broken = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: JSON_HEADERS, body: '{not json' });
    assert.equal(broken.status, 400, 'because the body must be JSON');
  } finally { await close(); }
});

test('Actions_UnknownId_NotFound', async () => {
  const { base, close } = await started();
  try {
    const missing = await fetch(`${base}/api/projects/project/actions/nope`, { headers: { authorization: 'Bearer tok' } });
    assert.equal(missing.status, 404, 'because an unknown action id is not found');
  } finally { await close(); }
});

test('Actions_PostWithoutJsonContentType_Refused', async () => {
  const { base, close } = await started();
  try {
    const plain = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: { authorization: 'Bearer tok', 'content-type': 'text/plain' }, body: JSON.stringify({ kind: 'refresh', args: {} }) });
    assert.equal(plain.status, 415, 'because a text/plain post is what a cross-site form or fetch can send without a preflight');
  } finally { await close(); }
});

test('Actions_PostWithoutToken_Unauthorized', async () => {
  const { base, close } = await started();
  try {
    const posted = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ kind: 'refresh', args: {} }) });
    assert.equal(posted.status, 401, 'because an action is never run for a caller without the secret');
  } finally { await close(); }
});

test('ForeignOrigin_Forbidden', async () => {
  const { base, close } = await started();
  try {
    const foreign = await fetch(`${base}/api/projects`, { headers: { authorization: 'Bearer tok', origin: 'https://evil.example' } });
    assert.equal(foreign.status, 403, 'because a page on another site must not read or drive the console, token or not');
    const local = await fetch(`${base}/api/projects`, { headers: { authorization: 'Bearer tok', origin: 'http://localhost:5173' } });
    assert.equal(local.status, 200, 'because the UI dev server is a local page');
    assert.equal(local.headers.get('access-control-allow-origin'), 'http://localhost:5173', 'because the allowed origin is echoed, never a wildcard');
  } finally { await close(); }
});

test('ForeignHost_Forbidden', async () => {
  const { base, close } = await started();
  try {
    const status = await new Promise<number>((resolve, reject) => {
      const sent = request(`${base}/healthz`, { headers: { authorization: 'Bearer tok', host: 'attacker.example' } }, (reply) => { reply.resume(); resolve(reply.statusCode ?? 0); });
      sent.on('error', reject);
      sent.end();
    });
    assert.equal(status, 403, 'because a DNS rebinding attack reaches the loopback with the attacker\'s Host header');
  } finally { await close(); }
});

test('BodyOverLimit_TooLarge', async () => {
  const { base, close } = await started();
  try {
    const big = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: JSON_HEADERS, body: JSON.stringify({ kind: 'gate.clear', args: { item: 'gh#7', message: 'x'.repeat(70000) } }) });
    assert.equal(big.status, 413, 'because the body limit protects the daemon and the client hears why');
  } finally { await close(); }
});
