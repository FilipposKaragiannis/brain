import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { test } from 'node:test';
import { WebSocket } from 'ws';
import { PANE_CLOSE } from '../src/paneProtocol.ts';
import { FIXTURE_ROOT } from './fakeRunner.ts';
import { AT_ROOT, connect, daemon, OTHER_PROJECT, paneUrl, PROJECT, refusedStatus, SOCKET_TIMEOUT_MILLISECONDS, startedClient, TOKEN, until } from './paneSocketRig.ts';

test('PaneUpgrade_RefusedBeforeTheHandshake_WithItsStatus', async () => {
  const running = await daemon();
  try {
    const rows = [
      { name: 'no token', url: paneUrl(running.port, { ...AT_ROOT, token: '' }, PROJECT.id), headers: {}, status: 401 },
      { name: 'a wrong token', url: paneUrl(running.port, { ...AT_ROOT, token: 'guess' }, PROJECT.id), headers: {}, status: 401 },
      { name: 'a foreign Origin', url: paneUrl(running.port, AT_ROOT, PROJECT.id), headers: { origin: 'https://evil.example' }, status: 403 },
      { name: 'a foreign Host', url: paneUrl(running.port, AT_ROOT, PROJECT.id), headers: { host: 'evil.example' }, status: 403 },
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
    await refusedStatus(paneUrl(running.port, AT_ROOT, PROJECT.id), { origin: 'https://evil.example' });
    assert.equal(running.ptys.length, 0, 'because a refused caller never starts a process');
  } finally { await running.close(); }
});

test('PaneUpgrade_LocalPageOrigin_Started', async () => {
  const running = await daemon();
  try {
    const client = connect(paneUrl(running.port, AT_ROOT, PROJECT.id), { origin: 'http://localhost:5173' });
    await until(() => client.notices.length > 0, 'the first frame');
    assert.equal(client.notices[0]?.type, 'started', 'because the console page itself may open a pane');
  } finally { await running.close(); }
});

test('UnlistedFolder_RefusedThenClosed4400', async () => {
  const running = await daemon();
  try {
    const client = connect(paneUrl(running.port, { ...AT_ROOT, path: '/etc' }, PROJECT.id), {});
    const code = await client.closed;
    assert.deepEqual([client.notices.map((notice) => notice.type), code], [['refused'], PANE_CLOSE.refused], 'because a page cannot read a failed handshake, so the refusal comes as a frame');
  } finally { await running.close(); }
});

test('UnlistedFolder_NoPtySpawned', async () => {
  const running = await daemon();
  try {
    await connect(paneUrl(running.port, { ...AT_ROOT, path: '/etc' }, PROJECT.id), {}).closed;
    assert.equal(running.ptys.length, 0, 'because the daemon refuses a folder the snapshot does not list');
  } finally { await running.close(); }
});

test('ListedFolder_ShellStartedThereAtTheRequestedSize', async () => {
  const running = await daemon();
  try {
    await startedClient(running.port, AT_ROOT, PROJECT.id);
    const pty = running.ptys[0]!;
    assert.deepEqual([pty.launch, pty.size], [{ command: '/bin/zsh', commandArguments: ['-l'], workingFolder: FIXTURE_ROOT }, { columns: 100, rows: 30 }], 'because the pane runs the owner\'s shell in the folder and size the page asked for');
  } finally { await running.close(); }
});

test('TypedBytes_ReachThePty', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    client.socket.send(Buffer.from('git status\r'), { binary: true });
    const pty = running.ptys[0]!;
    await until(() => pty.received.length > 0, 'the typed bytes');
    assert.equal(Buffer.concat(pty.received).toString('utf8'), 'git status\r', 'because a binary frame up is what the owner typed');
  } finally { await running.close(); }
});

test('PtyOutput_ReachesThePageAsBinary', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    running.ptys[0]!.emit(Buffer.from('\u001b[32mclean\u001b[0m'));
    await until(() => client.output.length > 0, 'the output');
    assert.equal(Buffer.concat(client.output).toString('utf8'), '\u001b[32mclean\u001b[0m', 'because a binary frame down is what the terminal drew, escapes and all');
  } finally { await running.close(); }
});

test('ResizeFrame_ReachesThePty', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    client.socket.send(JSON.stringify({ type: 'resize', cols: 143, rows: 37 }));
    const pty = running.ptys[0]!;
    await until(() => pty.size.columns === 143, 'the resize');
    assert.deepEqual(pty.size, { columns: 143, rows: 37 }, 'because the pty follows the page\'s terminal');
  } finally { await running.close(); }
});

test('UnknownTextFrame_Closed1008', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    client.socket.send(JSON.stringify({ type: 'exec', command: 'id' }));
    assert.equal(await client.closed, PANE_CLOSE.unknownFrame, 'because the daemon takes only resize and ack as text');
  } finally { await running.close(); }
});

const MALFORMED_TEXT_FRAMES: { frame: string; why: string }[] = [
  { frame: '{"type":', why: 'text that is not JSON' },
  { frame: '[{"type":"ack","bytes":1}]', why: 'a JSON array, though it holds a control' },
  { frame: 'null', why: 'JSON null' },
  { frame: '4096', why: 'a JSON number' },
  { frame: '{"type":"resize","cols":"143","rows":37}', why: 'a resize whose columns are a string' },
  { frame: '{"type":"resize","cols":143}', why: 'a resize with no rows' },
  { frame: '{"type":"ack","bytes":"4096"}', why: 'an ack whose byte count is a string' },
  { frame: '{"type":"ack"}', why: 'an ack with no byte count' },
];

for (const { frame, why } of MALFORMED_TEXT_FRAMES) {
  test(`MalformedTextFrame_Closed1008: ${why}`, async () => {
    const running = await daemon();
    try {
      const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
      client.socket.send(frame);
      assert.equal(await client.closed, PANE_CLOSE.unknownFrame, `because ${why} is not a control the daemon can act on`);
    } finally { await running.close(); }
  });
}

test('ProcessExit_ExitFrameThenClosed1000', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    running.ptys[0]!.exit(0, null);
    const code = await client.closed;
    assert.deepEqual([client.notices.at(-1), code], [{ type: 'exit', code: 0, signal: null }, PANE_CLOSE.ended], 'because the page says the session ended and how');
  } finally { await running.close(); }
});

test('ClientClosed_PtyHungUp', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    client.socket.close(1000);
    const pty = running.ptys[0]!;
    await until(() => pty.exited, 'the process to end');
    assert.equal(pty.exited, true, 'because closing the pane ends its process');
  } finally { await running.close(); }
});

test('StopAll_ClientClosed1001', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    await running.panes.stopAll();
    assert.equal(await client.closed, PANE_CLOSE.daemonStopping, 'because the page says the daemon stopped');
  } finally { await running.close(); }
});

test('StopAll_WithAPaneOpen_ServerCloseSettles', async () => {
  const running = await daemon();
  await startedClient(running.port, AT_ROOT, PROJECT.id);
  const closing = running.close().then(() => 'closed');
  let hungTimer: NodeJS.Timeout | undefined;
  const timeout = new Promise((resolve) => { hungTimer = setTimeout(() => resolve('hung'), SOCKET_TIMEOUT_MILLISECONDS); });
  try {
    assert.equal(await Promise.race([closing, timeout]), 'closed', 'because an upgraded socket must not hold the daemon open when it stops');
  } finally {
    clearTimeout(hungTimer);
  }
});

test('ProjectRemoved_ItsPaneClosed4404', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, AT_ROOT, PROJECT.id);
    await running.registry.apply([OTHER_PROJECT]);
    assert.equal(await client.closed, PANE_CLOSE.projectGone, 'because a pane of a project no longer watched cannot stay');
  } finally { await running.close(); }
});

test('ProjectRemoved_AnotherProjectsPane_StaysOpen', async () => {
  const running = await daemon();
  try {
    const gone = await startedClient(running.port, AT_ROOT, PROJECT.id);
    const kept = await startedClient(running.port, { ...AT_ROOT, path: OTHER_PROJECT.root }, OTHER_PROJECT.id);
    await running.registry.apply([OTHER_PROJECT]);
    await gone.closed;
    assert.equal(kept.socket.readyState, WebSocket.OPEN, 'because only the removed project loses its panes');
  } finally { await running.close(); }
});

test('QuickSession_Claude_SpawnsTheAbsoluteBinaryInTheFolder', async () => {
  const running = await daemon();
  try {
    await startedClient(running.port, { ...AT_ROOT, run: 'claude' }, PROJECT.id);
    const pty = running.ptys[0]!;
    assert.deepEqual([pty.launch.command, pty.launch.workingFolder], ['/opt/tools/bin/claude', FIXTURE_ROOT], 'because a quick session runs the agent found on the daemon\'s PATH, in the chosen folder');
  } finally { await running.close(); }
});

test('QuickSession_Started_FrameCarriesTheCommand', async () => {
  const running = await daemon();
  try {
    const client = await startedClient(running.port, { ...AT_ROOT, run: 'codex' }, PROJECT.id);
    const first = client.notices[0];
    assert.equal(first?.type === 'started' ? first.command[0] : null, '/opt/tools/bin/codex', 'because the tab\'s tooltip shows what the pane runs');
  } finally { await running.close(); }
});

/** A project whose flow config sets claude's model and effort, in a folder of its own. */
async function pairedProject(config: string): Promise<{ id: string; name: string; root: string }> {
  const root = await mkdtemp(path.join(os.tmpdir(), 'console-pane-paired-'));
  await mkdir(path.join(root, '.flow'));
  await writeFile(path.join(root, '.flow', 'config.yaml'), config);
  return { id: 'paired', name: 'paired', root };
}

test('QuickSession_ProjectSetsClaudesPair_SpawnedWithTheModelAndEffort', async () => {
  const running = await daemon();
  const paired = await pairedProject('jobs:\n  claude:\n    model: claude-sonnet-4-5\n    effort: xhigh\n');
  try {
    await running.registry.apply([PROJECT, OTHER_PROJECT, paired]);
    await running.registry.get(paired.id)!.monitor.refresh('files');
    await startedClient(running.port, { ...AT_ROOT, path: paired.root, run: 'claude' }, paired.id);
    assert.deepEqual(running.ptys[0]!.launch.commandArguments, ['--model', 'claude-sonnet-4-5', '--effort', 'xhigh'], 'because a quick session runs with the model and effort the project\'s flow config names');
  } finally {
    await running.close();
    await rm(paired.root, { recursive: true, force: true });
  }
});

test('QuickSession_ProjectSetsCodexsPair_SpawnedWithTheModelAndEffort', async () => {
  const running = await daemon();
  const paired = await pairedProject('jobs:\n  codex:\n    model: gpt-7-nova\n    effort: low\n');
  try {
    await running.registry.apply([PROJECT, OTHER_PROJECT, paired]);
    await running.registry.get(paired.id)!.monitor.refresh('files');
    await startedClient(running.port, { ...AT_ROOT, path: paired.root, run: 'codex' }, paired.id);
    assert.deepEqual(running.ptys[0]!.launch.commandArguments, ['-m', 'gpt-7-nova', '-c', 'model_reasoning_effort="low"'], 'because a codex quick session runs with the model and effort the project\'s flow config names for codex');
  } finally {
    await running.close();
    await rm(paired.root, { recursive: true, force: true });
  }
});
