import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { rm } from 'node:fs/promises';
import { WebSocket } from 'ws';
import type { RawData } from 'ws';
import { ActionRunner, realScheduler } from '../src/actions.ts';
import { FlowConfigEditor } from '../src/plugins/flow/configEditor.ts';
import { silentLogger } from '../src/log.ts';
import type { PaneHost } from '../src/panePlan.ts';
import type { PaneNotice } from '../src/paneProtocol.ts';
import { PaneSessions } from '../src/panes.ts';
import type { PtySpawner } from '../src/panes.ts';
import { ProjectMonitor } from '../src/project.ts';
import { ProjectRegistry } from '../src/registry.ts';
import { closeConsoleServer, createConsoleServer } from '../src/server.ts';
import { FIXTURE_ROOT, FIXTURES, fakeRunner, LONG_CADENCE } from './fakeRunner.ts';
import { fakePty } from './fakePty.ts';
import { plainSpawner } from './fakeSpawner.ts';
import { noSubagents } from './fakeSubagents.ts';
import type { FakePty } from './fakePty.ts';

const NOW = new Date('2026-11-11T09:30:00Z');
export const TOKEN = 'pane-token';
const STATE_DIR = path.join(os.tmpdir(), `console-pane-socket-${process.pid}`);
export const PROJECT = { id: 'project', name: 'project', root: FIXTURE_ROOT };
export const OTHER_PROJECT = { id: 'local', name: 'local', root: path.join(FIXTURES, 'project-local') };
const HOST: PaneHost = { shell: '/bin/zsh', environment: { PATH: '/usr/bin' }, isFolder: () => true };
/** How long a socket gets to do what a test waits for. */
export const SOCKET_TIMEOUT_MILLISECONDS = 5000;

export type Daemon = { registry: ProjectRegistry; panes: PaneSessions; ptys: FakePty[]; port: number; close(): Promise<void> };

export async function daemon(): Promise<Daemon> {
  const { spawner, ptys } = fakePty(null);
  return daemonOver(spawner, ptys);
}

/** A daemon whose panes start through `spawner`; `ptys` is what the test reads back. */
export async function daemonOver(spawner: PtySpawner, ptys: FakePty[]): Promise<Daemon> {
  const { spawner: actionSpawner } = plainSpawner();
  const registry = new ProjectRegistry((project) => {
    const monitor = new ProjectMonitor({ project, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE, subagents: noSubagents });
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

export function paneUrl(port: number, fields: Record<string, string>, projectId: string): string {
  return `ws://127.0.0.1:${port}/api/projects/${projectId}/panes?${new URLSearchParams(fields).toString()}`;
}

export const AT_ROOT = { path: FIXTURE_ROOT, run: 'shell', cols: '100', rows: '30', token: TOKEN };

export type Client = { socket: WebSocket; notices: PaneNotice[]; output: Buffer[]; closed: Promise<number> };

export function connect(url: string, headers: Record<string, string>): Client {
  const socket = new WebSocket(url, { headers });
  const notices: PaneNotice[] = [];
  const output: Buffer[] = [];
  socket.on('message', (rawFrame: RawData, isBinary: boolean) => {
    const buffer = Buffer.isBuffer(rawFrame) ? rawFrame : Buffer.from(rawFrame as ArrayBuffer);
    if (isBinary) output.push(buffer);
    else notices.push(JSON.parse(buffer.toString('utf8')) as PaneNotice);
  });
  const closed = new Promise<number>((resolve) => { socket.on('close', (code) => resolve(code)); });
  socket.on('error', () => {});
  return { socket, notices, output, closed };
}

/** The HTTP status a refused upgrade answered with. */
export function refusedStatus(url: string, headers: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers });
    socket.on('unexpected-response', (_request, response) => { resolve(response.statusCode ?? 0); socket.terminate(); });
    socket.on('open', () => { socket.terminate(); reject(new Error('the upgrade was accepted')); });
    socket.on('error', () => {});
  });
}

export async function until(condition: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + SOCKET_TIMEOUT_MILLISECONDS;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

export async function startedClient(port: number, fields: Record<string, string>, projectId: string): Promise<Client> {
  const client = connect(paneUrl(port, fields, projectId), {});
  await until(() => client.notices.length > 0, 'the first frame');
  return client;
}

/** The client's close code; throws once SOCKET_TIMEOUT_MILLISECONDS pass with the socket still open. */
export async function closeCode(client: Client): Promise<number> {
  let code: number | null = null;
  void client.closed.then((closedWith) => { code = closedWith; });
  await until(() => code !== null, 'the close');
  return code!;
}
