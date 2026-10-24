import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { AddressInfo } from 'node:net';
import { silentLogger } from '../src/log.ts';
import { ProjectMonitor } from '../src/project.ts';
import { createConsoleServer } from '../src/server.ts';
import type { Snapshot } from '../src/snapshot.ts';
import { FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LONG_CADENCE = { filesMs: 600000, gitMs: 600000, processesMs: 600000, jobsMs: 600000, boardMs: 600000 };

async function started(): Promise<{ monitor: ProjectMonitor; base: string; close: () => Promise<void> }> {
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE });
  const server = createConsoleServer([monitor], { host: '127.0.0.1', port: 0, token: 'tok', log: silentLogger });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  await monitor.start();
  await monitor.refresh('board');
  const { port } = server.address() as AddressInfo;
  return { monitor, base: `http://127.0.0.1:${port}`, close: async () => { monitor.stop(); await new Promise<void>((resolve) => server.close(() => resolve())); } };
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
