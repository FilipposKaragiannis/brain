import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { rm } from 'node:fs/promises';
import { test } from 'node:test';
import { WebSocket } from 'ws';
import type { RawData } from 'ws';
import { ActionRunner, realScheduler } from '../src/actions.ts';
import { FlowConfigEditor } from '../src/plugins/flow/configEditor.ts';
import { silentLogger } from '../src/log.ts';
import type { PaneHost } from '../src/panePlan.ts';
import type { PaneNotice } from '../src/paneProtocol.ts';
import { PANE_CLOSE } from '../src/paneProtocol.ts';
import { PaneSessions } from '../src/panes.ts';
import { ProjectMonitor } from '../src/project.ts';
import { ProjectRegistry } from '../src/registry.ts';
import { closeConsoleServer, createConsoleServer } from '../src/server.ts';
import { FIXTURE_ROOT, FIXTURES, fakeRunner } from './fakeRunner.ts';
import { fakePty } from './fakePty.ts';
import { plainSpawner } from './fakeSpawner.ts';
import type { FakePty } from './fakePty.ts';

const NOW = new Date('2026-11-11T09:30:00Z');
const LONG_CADENCE = { filesMs: 600000, gitMs: 600000, processesMs: 600000, jobsMs: 600000, boardMs: 600000, pullsMs: 600000 };
const TOKEN = 'pane-token';
const STATE_DIR = path.join(os.tmpdir(), `console-pane-socket-${process.pid}`);
const PROJECT = { id: 'project', name: 'project', root: FIXTURE_ROOT };
const OTHER_PROJECT = { id: 'local', name: 'local', root: path.join(FIXTURES, 'project-local') };
const BINARIES: Record<string, string> = { claude: '/opt/tools/bin/claude', codex: '/opt/tools/bin/codex' };
const HOST: PaneHost = { shell: '/bin/zsh', environment: { PATH: '/usr/bin' }, isFolder: () => true, executable: (name) => BINARIES[name] ?? null };
/** How long a socket gets to do what a test waits for. */
const SOCKET_TIMEOUT_MS = 5000;

type Daemon = { registry: ProjectRegistry; panes: PaneSessions; ptys: FakePty[]; port: number; close(): Promise<void> };

async function daemon(): Promise<Daemon> {
  const { spawner, ptys } = fakePty();
  const { spawner: actionSpawner } = plainSpawner();
  const registry = new ProjectRegistry((project) => {
    const monitor = new ProjectMonitor({ project, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE });
    const actions = new ActionRunner({ projectId: project.id, context: () => monitor.actionContext(), spawner: actionSpawner, scheduler: realScheduler, clock: () => NOW, log: silentLogger, stateDir: STATE_DIR, onRefresh: () => {} });
    return { monitor, actions, flowConfig: new FlowConfigEditor({ projectId: project.id, root: project.root, runner: fakeRunner, refresh: () => monitor.refresh('files'), log: silentLogger, home: path.join(FIXTURES, 'home') }) };
  }, silentLogger);
  const panes = new PaneSessions({ spawner, host: HOST, scheduler: realScheduler, log: silentLogger });
  const server = createConsoleServer(registry, null, { host: '127.0.0.1', port: 0, token: TOKEN, staticDir: null, log: silentLogger, panes });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  await registry.apply([PROJECT, OTHER_PROJECT]);
  await Promise.all([PROJECT, OTHER_PROJECT].map((project) => registry.get(project.id)!.monitor.refresh('git')));
  const { port } = server.address() as AddressInfo;
  return {
    registry, panes, ptys, port,
    close: async () => { await panes.stopAll(); registry.stopAll(); await registry.whenIdle(); await closeConsoleServer(server); await rm(STATE_DIR, { recursive: true, force: true }); },
  };
}

function paneUrl(port: number, fields: Record<string, string>, projectId = PROJECT.id): string {
  return `ws://127.0.0.1:${port}/api/projects/${projectId}/panes?${new URLSearchParams(fields).toString()}`;
}

const AT_ROOT = { path: FIXTURE_ROOT, run: 'shell', cols: '100', rows: '30', token: TOKEN };

type Client = { socket: WebSocket; notices: PaneNotice[]; output: Buffer[]; closed: Promise<number> };

function connect(url: string, headers: Record<string, string> = {}): Client {
  const socket = new WebSocket(url, { headers });
  const notices: PaneNotice[] = [];
  const output: Buffer[] = [];
  socket.on('message', (data: RawData, isBinary: boolean) => {
    const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer);
    if (isBinary) output.push(buffer);
    else notices.push(JSON.parse(buffer.toString('utf8')) as PaneNotice);
  });
  const closed = new Promise<number>((resolve) => { socket.on('close', (code) => resolve(code)); });
  socket.on('error', () => {});
  return { socket, notices, output, closed };
}

/** The HTTP status a refused upgrade answered with. */
function refusedStatus(url: string, headers: Record<string, string> = {}): Promise<number> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers });
    socket.on('unexpected-response', (_request, response) => { resolve(response.statusCode ?? 0); socket.terminate(); });
    socket.on('open', () => { socket.terminate(); reject(new Error('the upgrade was accepted')); });
    socket.on('error', () => {});
  });
}

async function until(condition: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + SOCKET_TIMEOUT_MS;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

async function startedClient(port: number, fields: Record<string, string> = AT_ROOT, projectId = PROJECT.id): Promise<Client> {
  const client = connect(paneUrl(port, fields, projectId));
  await until(() => client.notices.length > 0, 'the first frame');
  return client;
}

test('PaneUpgrade_RefusedBeforeTheHandshake_WithItsStatus', async () => {
  const running = await daemon();
  try {
    const rows = [
      { name: 'no token', url: paneUrl(running.port, { ...AT_ROOT, token: '' }), headers: {}, status: 401 },
      { name: 'a wrong token', url: paneUrl(running.port, { ...AT_ROOT, token: 'guess' }), headers: {}, status: 401 },
      { name: 'a foreign Origin', url: paneUrl(running.port, AT_ROOT), headers: { origin: 'https://evil.example' }, status: 403 },
      { name: 'a foreign Host', url: paneUrl(running.port, AT_ROOT), headers: { host: 'evil.example' }, status: 403 },
      { name: 'an unknown project', url: paneUrl(running.port, AT_ROOT, 'nobody'), headers: {}, status: 404 },
      { name: 'another path', url: `ws://127.0.0.1:${running.port}/api/projects/project/shell?token=${TOKEN}`, headers: {}, status: 404 },
    ];
    for (const row of rows) {
      assert.equal(await refusedStatus(row.url, row.headers), row.status, `because ${row.name} must never reach a shell`);
    }
  } finally { await running.close(); }
});

test('PaneUpgrade_Refused_NoPtySpawned', async () => {
  const running = await daemon();
  try {
    await refusedStatus(paneUrl(running.port, AT_ROOT), { origin: 'https://evil.example' });
    assert.equal(running.ptys.length, 0, 'because a refused caller never starts a process');
  } finally { await running.close(); }
});

test('PaneUpgrade_LocalPageOrigin_Started', async () => {
  const running = await daemon();
  try {
    const client = connect(paneUrl(running.port, AT_ROOT), { origin: 'http://localhost:5173' });
    await until(() => client.notices.length > 0, 'the first frame');
    assert.equal(client.notices[0]?.type, 'started', 'because the console page itself may open a pane');
  } finally { await running.close(); }
});

test('UnlistedFolder_RefusedThenClosed4400', async () => {
  const running = await daemon();
  try {
    const client = connect(paneUrl(running.port, { ...AT_ROOT, path: '/etc' }));
    const code = await client.closed;
    assert.deepEqual([client.notices.map((notice) => notice.type), code], [['refused'], PANE_CLOSE.refused], 'because a page cannot read a failed handshake, so the refusal comes as a frame');
  } finally { await running.close(); }
});

test('UnlistedFolder_NoPtySpawned', async () => {
  const running = await daemon();
  try {
    await connect(paneUrl(running.port, { ...AT_ROOT, path: '/etc' })).closed;
    assert.equal(running.ptys.length, 0, 'because the daemon refuses a folder the snapshot does not list');
  } finally { await running.close(); }
});

test('ListedFolder_ShellStartedThereAtTheRequestedSize', async () => {
  const running = await daemon();
  try {
    await startedClient(running.port);
    const pty = running.ptys[0]!;
    assert.deepEqual([pty.launch, pty.size], [{ command: '/bin/zsh', args: ['-l'], cwd: FIXTURE_ROOT }, { cols: 100, rows: 30 }], 'because the pane runs the owner\'s shell in the folder and size the page asked for');
  } finally { await running.close(); }
});

test('TypedBytes_ReachThePty', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    client.socket.send(Buffer.from('git status\r'), { binary: true });
    const pty = running.ptys[0]!;
    await until(() => pty.received.length > 0, 'the typed bytes');
    assert.equal(Buffer.concat(pty.received).toString('utf8'), 'git status\r', 'because a binary frame up is what the owner typed');
  } finally { await running.close(); }
});

test('PtyOutput_ReachesThePageAsBinary', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    running.ptys[0]!.emit(Buffer.from('\u001b[32mclean\u001b[0m'));
    await until(() => client.output.length > 0, 'the output');
    assert.equal(Buffer.concat(client.output).toString('utf8'), '\u001b[32mclean\u001b[0m', 'because a binary frame down is what the terminal drew, escapes and all');
  } finally { await running.close(); }
});

test('ResizeFrame_ReachesThePty', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    client.socket.send(JSON.stringify({ type: 'resize', cols: 143, rows: 37 }));
    const pty = running.ptys[0]!;
    await until(() => pty.size.cols === 143, 'the resize');
    assert.deepEqual(pty.size, { cols: 143, rows: 37 }, 'because the pty follows the page\'s terminal');
  } finally { await running.close(); }
});

test('UnknownTextFrame_Closed1008', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    client.socket.send(JSON.stringify({ type: 'exec', command: 'id' }));
    assert.equal(await client.closed, PANE_CLOSE.unknownFrame, 'because the daemon takes only resize and ack as text');
  } finally { await running.close(); }
});

test('ProcessExit_ExitFrameThenClosed1000', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    running.ptys[0]!.exit(0, null);
    const code = await client.closed;
    assert.deepEqual([client.notices.at(-1), code], [{ type: 'exit', code: 0, signal: null }, PANE_CLOSE.ended], 'because the page says the session ended and how');
  } finally { await running.close(); }
});

test('ClientClosed_PtyHungUp', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    client.socket.close(1000);
    const pty = running.ptys[0]!;
    await until(() => pty.signals.length > 0, 'the hang-up');
    assert.deepEqual(pty.signals, ['SIGHUP'], 'because closing the pane ends its process');
  } finally { await running.close(); }
});

test('StopAll_ClientClosed1001', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    await running.panes.stopAll();
    assert.equal(await client.closed, PANE_CLOSE.daemonStopping, 'because the page says the daemon stopped');
  } finally { await running.close(); }
});

test('StopAll_WithAPaneOpen_ServerCloseSettles', async () => {
  const running = await daemon();
  await startedClient(running.port);
  const closing = running.close().then(() => 'closed');
  const timeout = new Promise((resolve) => setTimeout(() => resolve('hung'), SOCKET_TIMEOUT_MS));
  assert.equal(await Promise.race([closing, timeout]), 'closed', 'because an upgraded socket must not hold the daemon open when it stops');
});

test('ProjectRemoved_ItsPaneClosed4404', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port);
    await running.registry.apply([OTHER_PROJECT]);
    assert.equal(await client.closed, PANE_CLOSE.projectGone, 'because a pane of a project no longer watched cannot stay');
  } finally { await running.close(); }
});

test('ProjectRemoved_AnotherProjectsPane_StaysOpen', async () => {
  const running = await daemon();
  try {
    const gone = await startedClient(running.port);
    const kept = await startedClient(running.port, { ...AT_ROOT, path: OTHER_PROJECT.root }, OTHER_PROJECT.id);
    await running.registry.apply([OTHER_PROJECT]);
    await gone.closed;
    assert.equal(kept.socket.readyState, WebSocket.OPEN, 'because only the removed project loses its panes');
  } finally { await running.close(); }
});

test('QuickSession_Claude_SpawnsTheAbsoluteBinaryInTheFolder', async () => {
  const running = await daemon();
  try {
    await startedClient(running.port, { ...AT_ROOT, run: 'claude' });
    const pty = running.ptys[0]!;
    assert.deepEqual([pty.launch.command, pty.launch.cwd], ['/opt/tools/bin/claude', FIXTURE_ROOT], 'because a quick session runs the agent found on the daemon\'s PATH, in the chosen folder');
  } finally { await running.close(); }
});

test('QuickSession_Started_FrameCarriesTheCommand', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, { ...AT_ROOT, run: 'codex' });
    const first = client.notices[0];
    assert.equal(first?.type === 'started' ? first.command[0] : null, '/opt/tools/bin/codex', 'because the tab\'s tooltip shows what the pane runs');
  } finally { await running.close(); }
});
