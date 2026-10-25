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
import { FlowConfigEditor } from '../src/plugins/flow/configEditor.ts';
import { ProjectRegistry } from '../src/registry.ts';
import { SettingsStore } from '../src/settings.ts';
import { readConfig } from '../src/config.ts';
import type { DaemonConfig } from '../src/config.ts';
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { closeConsoleServer, createConsoleServer } from '../src/server.ts';
import type { Snapshot } from '../src/snapshot.ts';
import { FIXTURE_ROOT, FIXTURES, fakeRunner } from './fakeRunner.ts';
import { plainSpawner } from './fakeSpawner.ts';
import type { FakeProcess } from './fakeSpawner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LONG_CADENCE = { filesMs: 600000, gitMs: 600000, processesMs: 600000, jobsMs: 600000, boardMs: 600000, pullsMs: 600000 };

const PROJECT = { id: 'project', name: 'project', root: FIXTURE_ROOT };

async function started(makeSettings: (registry: ProjectRegistry) => SettingsStore | null = () => null): Promise<{ monitor: ProjectMonitor; processes: FakeProcess[]; base: string; close: () => Promise<void> }> {
  const { spawner, processes } = plainSpawner();
  const stateDir = path.join(os.tmpdir(), `console-server-${process.pid}`);
  const registry = new ProjectRegistry((project) => {
    const monitor = new ProjectMonitor({ project, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE });
    const actions = new ActionRunner({ projectId: project.id, context: () => monitor.actionContext(), spawner, scheduler: realScheduler, clock: () => NOW, log: silentLogger, stateDir, onRefresh: () => {} });
    return { monitor, actions, flowConfig: new FlowConfigEditor({ projectId: project.id, root: project.root, runner: fakeRunner, refresh: () => monitor.refresh('files'), log: silentLogger }) };
  }, silentLogger);
  const server = createConsoleServer(registry, makeSettings(registry), { host: '127.0.0.1', port: 0, token: 'tok', staticDir: null, log: silentLogger });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  await registry.apply([PROJECT]);
  const monitor = registry.get('project')!.monitor;
  await monitor.refresh('board');
  const { port } = server.address() as AddressInfo;
  return { monitor, processes, base: `http://127.0.0.1:${port}`, close: async () => { registry.stopAll(); await closeConsoleServer(server); await rm(stateDir, { recursive: true, force: true }); } };
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

test('Events_ItemAndLimit_KeptEventsAsJson', async () => {
  const { base, close } = await started();
  try {
    const response = await fetch(`${base}/api/projects/project/events?item=${encodeURIComponent('gh#213')}&limit=1&token=tok`);
    const body = (await response.json()) as { events: { item: string; kind: string }[]; total: number; kept: number };
    assert.deepEqual([body.events.map((event) => [event.item, event.kind]), body.total], [[['gh#213', 'comments']], 2], 'because an Activity screen asks for one item\'s events, newest first, and learns there are more');
  } finally { await close(); }
});

test('Events_AcceptJson_AllKeptEvents', async () => {
  const { base, close } = await started();
  try {
    const response = await fetch(`${base}/api/projects/project/events`, { headers: { authorization: 'Bearer tok', accept: 'application/json' } });
    assert.equal(((await response.json()) as { total: number }).total, 3, 'because a JSON caller gets every kept event, not the stream');
  } finally { await close(); }
});

test('Events_BadLimit_BadRequest', async () => {
  const { base, close } = await started();
  try {
    assert.equal((await fetch(`${base}/api/projects/project/events?limit=-1&token=tok`)).status, 400, 'because a limit is a positive whole number');
  } finally { await close(); }
});

test('Events_NoQuery_StillTheStream', async () => {
  const { base, close } = await started();
  try {
    const controller = new AbortController();
    const response = await fetch(`${base}/api/projects/project/events?token=tok`, { signal: controller.signal });
    const type = response.headers.get('content-type');
    controller.abort();
    assert.equal(type, 'text/event-stream', 'because an EventSource asks with no query and must get the live stream, not the JSON list');
  } finally { await close(); }
});

test('Events_Post_MethodNotAllowed', async () => {
  const { base, close } = await started();
  try {
    assert.equal((await fetch(`${base}/api/projects/project/events?item=gh%23213&token=tok`, { method: 'POST' })).status, 405, 'because the events are only ever read');
  } finally { await close(); }
});

test('Close_WithAStreamOpen_FinishesWithoutWaitingForIt', async () => {
  const { base, close } = await started();
  const controller = new AbortController();
  const stream = fetch(`${base}/api/projects/project/events?token=tok`, { signal: controller.signal });
  await stream.then((response) => response.body?.getReader().read());
  const began = Date.now();
  await close();
  controller.abort();
  assert.ok(Date.now() - began < 2000, 'because a console tab left open must not keep Ctrl+C from stopping the daemon');
});

/** Settings over a fresh config folder whose file names the fixture project, applied to the server's registry. */
function fileSettings(registry: ProjectRegistry): SettingsStore {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-server-settings-'));
  writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ projects: [{ root: FIXTURE_ROOT }] }));
  const read = readConfig([], { BRAIN_CONSOLE_TOKEN: 'tok', BRAIN_CONSOLE_STATE: dir }, { configFile: path.join(dir, 'config.json'), legacyProjectsFile: path.join(dir, 'projects.json') });
  const config = (read as { config: DaemonConfig }).config;
  return new SettingsStore({ config, installed: () => ['iterm'], applyProjects: (projects) => { void registry.apply(projects); } });
}

const LOCAL_ROOT = path.join(FIXTURES, 'project-local');

test('Settings_GetWithToken_EffectiveSettingsAndOrigins', async () => {
  const { base, close } = await started(fileSettings);
  try {
    const response = await fetch(`${base}/api/settings`, { headers: { authorization: 'Bearer tok' } });
    const view = (await response.json()) as { projects: { from: string; roots: string[] }; terminal: { installed: string[] } };
    assert.deepEqual([view.projects.from, view.projects.roots, view.terminal.installed], ['file', [FIXTURE_ROOT], ['iterm']], 'because the screen shows each setting with where it came from');
    assert.equal((await fetch(`${base}/api/settings`)).status, 401, 'because the settings sit behind the token like every route');
  } finally { await close(); }
});

test('Settings_PutBadRoot_BadRequestWithTheReason', async () => {
  const { base, close } = await started(fileSettings);
  try {
    const response = await fetch(`${base}/api/settings`, { method: 'PUT', headers: JSON_HEADERS, body: JSON.stringify({ projects: [{ root: '/nowhere/at/all' }] }) });
    assert.equal(response.status, 400, 'because a root without a flow is refused');
    assert.match(((await response.json()) as { error: string }).error, /\.flow\/config\.yaml/, 'because the owner hears what is missing');
  } finally { await close(); }
});

test('Settings_PutWithoutJson_Refused', async () => {
  const { base, close } = await started(fileSettings);
  try {
    const response = await fetch(`${base}/api/settings`, { method: 'PUT', headers: { authorization: 'Bearer tok', 'content-type': 'text/plain' }, body: '{}' });
    assert.equal(response.status, 415, 'because a cross-site form can send text/plain without a preflight');
  } finally { await close(); }
});

test('Settings_PutNewProject_ListedAndAnnouncedOnTheStream', async () => {
  const { base, close } = await started(fileSettings);
  try {
    const stream = await fetch(`${base}/api/projects/project/events?token=tok`, { signal: AbortSignal.timeout(5000) });
    const reader = stream.body!.getReader();
    const put = await fetch(`${base}/api/settings`, { method: 'PUT', headers: JSON_HEADERS, body: JSON.stringify({ projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] }) });
    assert.equal(put.status, 200, 'because both roots hold a flow');
    let text = '';
    while (!text.includes('event: projects')) text += new TextDecoder().decode((await reader.read()).value);
    assert.match(text, /event: projects\ndata: \[[^\n]*"project-local"/, 'because an open page learns of the new project without a reload');
    const listed = (await (await fetch(`${base}/api/projects`, { headers: { authorization: 'Bearer tok' } })).json()) as { id: string }[];
    assert.deepEqual(listed.map((project) => project.id), ['project', 'project-local'], 'because the daemon watches the new root without a restart');
    await reader.cancel();
  } finally { await close(); }
});

test('Settings_PutRemovesTheProject_ItsStreamEnds', async () => {
  const { base, close } = await started(fileSettings);
  try {
    const stream = await fetch(`${base}/api/projects/project/events?token=tok`, { signal: AbortSignal.timeout(5000) });
    const reader = stream.body!.getReader();
    await fetch(`${base}/api/settings`, { method: 'PUT', headers: JSON_HEADERS, body: JSON.stringify({ projects: [{ root: LOCAL_ROOT }] }) });
    let text = '';
    for (let chunk = await reader.read(); !chunk.done; chunk = await reader.read()) text += new TextDecoder().decode(chunk.value);
    assert.match(text, /event: projects/, 'because the page hears the new list before its stream ends');
    assert.equal((await fetch(`${base}/api/projects/project/snapshot?token=tok`)).status, 404, 'because a removed project is no longer served');
  } finally { await close(); }
});

test('Settings_PutMovesTheIdToAnotherRoot_TheOldStreamEnds', async () => {
  const moved = path.join(mkdtempSync(path.join(os.tmpdir(), 'console-moved-')), 'project');
  mkdirSync(path.join(moved, '.flow'), { recursive: true });
  copyFileSync(path.join(FIXTURE_ROOT, '.flow', 'config.yaml'), path.join(moved, '.flow', 'config.yaml'));
  const { base, close } = await started(fileSettings);
  try {
    const stream = await fetch(`${base}/api/projects/project/events?token=tok`, { signal: AbortSignal.timeout(5000) });
    const reader = stream.body!.getReader();
    const put = await fetch(`${base}/api/settings`, { method: 'PUT', headers: JSON_HEADERS, body: JSON.stringify({ projects: [{ root: moved }] }) });
    assert.equal(put.status, 200, 'because the new root holds a flow');
    const drained = (async (): Promise<string> => { for (let chunk = await reader.read(); !chunk.done; chunk = await reader.read()) { /* read until the server ends it */ } return 'ended'; })();
    const outcome = await Promise.race([drained, new Promise<string>((resolve) => setTimeout(() => resolve('still open'), 3000))]);
    assert.equal(outcome, 'ended', 'because a stream on the stopped monitor would never carry another snapshot, so it ends and the page opens a new one');
    if (outcome !== 'ended') await reader.cancel();
  } finally { await close(); }
});

test('FlowConfig_ServedWithItsHashAndSections', async () => {
  const { base, close } = await started();
  try {
    const response = await fetch(`${base}/api/projects/project/plugins/flow/config`, { headers: { authorization: 'Bearer tok' } });
    const document = (await response.json()) as { path: string; hash: string; sections: { group: string }[] };
    assert.equal(response.status, 200, 'because the fixture project has a .flow/config.yaml');
    assert.equal(document.path, path.join(FIXTURE_ROOT, '.flow', 'config.yaml'), 'because the editor names the file it edits');
    assert.match(document.hash, /^[0-9a-f]{64}$/, 'because a PUT must send the hash back');
    assert.deepEqual(document.sections.map((section) => section.group).slice(0, 2), ['Tracker', 'Readiness'], 'because the schema groups come in a fixed order');
  } finally { await close(); }
});

test('FlowConfigPut_WithoutJson_Refused', async () => {
  const { base, close } = await started();
  try {
    const response = await fetch(`${base}/api/projects/project/plugins/flow/config`, { method: 'PUT', headers: { authorization: 'Bearer tok' }, body: 'base: dev' });
    assert.equal(response.status, 415, 'because the body is JSON with the hash, never a bare file');
  } finally { await close(); }
});
