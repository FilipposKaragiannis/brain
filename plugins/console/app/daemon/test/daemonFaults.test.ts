import assert from 'node:assert/strict';
import { connect as connectTcp } from 'node:net';
import { test } from 'node:test';
import { MAXIMUM_PANES, PANE_CLOSE } from '../src/paneProtocol.ts';
import type { PtySpawner } from '../src/panes.ts';
import { fakePty } from './fakePty.ts';
import { AT_ROOT, closeCode, connect, daemon, daemonOver, paneUrl, PROJECT, refusedStatus, SOCKET_TIMEOUT_MILLISECONDS, startedClient, TOKEN } from './paneSocketRig.ts';

test('PaneUpgrade_ProjectIdThatDoesNotDecode_404', async () => {
  const running = await daemon();
  try {
    const status = await refusedStatus(`ws://127.0.0.1:${running.port}/api/projects/%E0/panes?token=${TOKEN}`, {});
    assert.equal(status, 404, 'because a malformed project id names no project');
  } finally { await running.close(); }
});

test('PaneUpgrade_ProjectIdThatDoesNotDecode_DaemonServesTheNextPane', async () => {
  const running = await daemon();
  try {
    await refusedStatus(`ws://127.0.0.1:${running.port}/api/projects/%E0/panes?token=${TOKEN}`, {});
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    assert.deepEqual(client.notices.map((notice) => notice.type), ['started'], 'because one bad request must not end the daemon and every pane with it');
  } finally { await running.close(); }
});

/** How many callers send a refused upgrade and reset the connection before the daemon answers. */
const RESETTING_CALLERS = 20;

/** A raw WebSocket upgrade of `target` with no token, as a client that checks nothing sends it. */
function upgradeRequest(port: number, target: string): string {
  return `GET ${target} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`;
}

/** Sends a pane upgrade with no token, then resets the connection at once, as a dropped client does. */
function upgradeThenReset(port: number): Promise<void> {
  return new Promise((resolve) => {
    const caller = connectTcp(port, '127.0.0.1', () => {
      caller.write(upgradeRequest(port, `/api/projects/${PROJECT.id}/panes`));
      caller.resetAndDestroy();
    });
    caller.on('error', () => {});
    caller.on('close', () => resolve());
  });
}

test('RefusedUpgradeResetByThePeer_DaemonServesTheNextPane', async () => {
  const running = await daemon();
  try {
    for (let caller = 0; caller < RESETTING_CALLERS; caller += 1) await upgradeThenReset(running.port);
    await new Promise((resolve) => setTimeout(resolve, 50));
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    assert.deepEqual(client.notices.map((notice) => notice.type), ['started'], 'because a caller that hangs up on its refusal must not end the daemon and every pane with it');
  } finally { await running.close(); }
});

const THROWING_SPAWNER: PtySpawner = () => { throw new Error('posix_spawnp failed: EMFILE'); };

test('SpawnerThrows_RefusedWithTheReasonThenClosed4400', async () => {
  const running = await daemonOver(THROWING_SPAWNER, []);
  try {
    const client = connect(paneUrl(running.port, AT_ROOT, PROJECT.id), {});
    const code = await closeCode(client);
    const told = client.notices.map((notice) => notice.type === 'refused' ? { type: notice.type, named: notice.error.includes('EMFILE') } : notice);
    assert.deepEqual([told, code], [[{ type: 'refused', named: true }], PANE_CLOSE.refused], 'because a start that throws is a refusal the page can show, not a daemon crash');
  } finally { await running.close(); }
});

test('SpawnerThrows_DaemonServesTheNextPane', async () => {
  let failing = true;
  const { spawner: working, ptys } = fakePty(null);
  const flaky: PtySpawner = (launch, size, environment) => {
    if (failing) throw new Error('posix_spawnp failed: EMFILE');
    return working(launch, size, environment);
  };
  const running = await daemonOver(flaky, ptys);
  try {
    await closeCode(connect(paneUrl(running.port, AT_ROOT, PROJECT.id), {}));
    failing = false;
    const next = await startedClient(running.port, AT_ROOT, PROJECT.id);
    assert.equal(next.notices[0]?.type, 'started', 'because a throw inside the upgrade callback must not take the daemon down');
  } finally { await running.close(); }
});

test('SpawnerThrows_RefusedPanesDoNotCountAgainstTheLimit', async () => {
  let failing = true;
  const { spawner: working, ptys } = fakePty(null);
  const flaky: PtySpawner = (launch, size, environment) => {
    if (failing) throw new Error('posix_spawnp failed: EMFILE');
    return working(launch, size, environment);
  };
  const running = await daemonOver(flaky, ptys);
  try {
    for (let attempt = 0; attempt < MAXIMUM_PANES; attempt += 1) await closeCode(connect(paneUrl(running.port, AT_ROOT, PROJECT.id), {}));
    failing = false;
    const next = await startedClient(running.port, AT_ROOT, PROJECT.id);
    assert.equal(next.notices[0]?.type, 'started', 'because a pane whose start threw never ran, so it holds no place under the limit');
  } finally { await running.close(); }
});

/** A request target the HTTP parser lets through and `new URL` cannot parse. */
const UNPARSED_TARGET = '//';
const HTTP_OK = 200;
const HTTP_BAD_REQUEST = 400;

/** Writes `request` raw over TCP and reads the status of the answer; 0 when the connection closes, or goes quiet for SOCKET_TIMEOUT_MILLISECONDS, with none. */
function rawStatus(port: number, request: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const caller = connectTcp(port, '127.0.0.1', () => caller.write(request));
    caller.setTimeout(SOCKET_TIMEOUT_MILLISECONDS, () => caller.destroy());
    caller.on('data', (chunk: Buffer) => { chunks.push(chunk); });
    caller.on('error', reject);
    caller.on('close', () => {
      const status = /^HTTP\/1\.1 (\d{3}) /.exec(Buffer.concat(chunks).toString('latin1'));
      resolve(status === null ? 0 : Number(status[1]));
    });
  });
}

function routeRequest(port: number, target: string): string {
  return `GET ${target} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`;
}

test('PaneUpgrade_UrlThatDoesNotParse_400', async () => {
  const running = await daemon();
  try {
    const status = await rawStatus(running.port, upgradeRequest(running.port, UNPARSED_TARGET));
    assert.equal(status, HTTP_BAD_REQUEST, 'because an upgrade whose URL does not parse is a bad request, refused before the handshake');
  } finally { await running.close(); }
});

test('PaneUpgrade_UrlThatDoesNotParse_DaemonServesTheNextPane', async () => {
  const running = await daemon();
  try {
    await rawStatus(running.port, upgradeRequest(running.port, UNPARSED_TARGET));
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    assert.deepEqual(client.notices.map((notice) => notice.type), ['started'], 'because one malformed upgrade must not end the daemon and every pane with it');
  } finally { await running.close(); }
});

test('Request_UrlThatDoesNotParse_400', async () => {
  const running = await daemon();
  try {
    const status = await rawStatus(running.port, routeRequest(running.port, UNPARSED_TARGET));
    assert.equal(status, HTTP_BAD_REQUEST, 'because a request whose URL does not parse is a bad request, not a crash');
  } finally { await running.close(); }
});

test('Request_UrlThatDoesNotParse_DaemonServesTheNextRequest', async () => {
  const running = await daemon();
  try {
    await rawStatus(running.port, routeRequest(running.port, UNPARSED_TARGET));
    const status = await rawStatus(running.port, routeRequest(running.port, `/healthz?token=${TOKEN}`));
    assert.equal(status, HTTP_OK, 'because one malformed request must not end the daemon');
  } finally { await running.close(); }
});
