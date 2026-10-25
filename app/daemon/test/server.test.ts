import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rm } from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { ActionRunner } from '../src/actions.ts';
import { silentLogger } from '../src/log.ts';
import { ProjectMonitor } from '../src/project.ts';
import { createConsoleServer } from '../src/server.ts';
import type { Snapshot } from '../src/snapshot.ts';
import { FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';
import { fakeSpawner } from './fakeSpawner.ts';
import type { FakeProcess } from './fakeSpawner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LONG_CADENCE = { filesMs: 600000, gitMs: 600000, processesMs: 600000, jobsMs: 600000, boardMs: 600000 };

async function started(): Promise<{ monitor: ProjectMonitor; processes: FakeProcess[]; base: string; close: () => Promise<void> }> {
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE });
  const { spawner, processes } = fakeSpawner();
  const stateDir = path.join(os.tmpdir(), `console-server-${process.pid}`);
  const actions = new ActionRunner({ projectId: 'project', context: () => monitor.actionContext(), spawner, clock: () => NOW, log: silentLogger, stateDir, onRefresh: () => {} });
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
    processes[0]!.exit(0);
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

test('Actions_BadKind_BadRequest', async () => {
  const { base, close } = await started();
  try {
    const posted = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: { authorization: 'Bearer tok' }, body: JSON.stringify({ kind: 'shell', args: {} }) });
    assert.equal(posted.status, 400, 'because only allow-listed kinds run');
    const broken = await fetch(`${base}/api/projects/project/actions`, { method: 'POST', headers: { authorization: 'Bearer tok' }, body: '{not json' });
    assert.equal(broken.status, 400, 'because the body must be JSON');
    const missing = await fetch(`${base}/api/projects/project/actions/nope`, { headers: { authorization: 'Bearer tok' } });
    assert.equal(missing.status, 404, 'because an unknown action id is not found');
  } finally { await close(); }
});
