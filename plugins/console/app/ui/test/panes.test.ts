import { expect, test } from 'vitest';
import { ACK_EVERY_BYTES, PANE_CLOSE } from '../../daemon/src/paneProtocol.ts';
import type { PaneNotice, PaneTarget } from '../../daemon/src/paneProtocol.ts';
import { PANE_END_WORDS, PaneStore } from '../src/panes.ts';
import type { PaneView } from '../src/panes.ts';
import { FAKE_TERMINAL_SIZE, FakeDaemon } from './fakeDaemon.tsx';
import type { FakeSocket, FakeTerminal } from './fakeDaemon.tsx';

const PROJECT = 'foosbrawl';
const WORKTREE = '/work/foosbrawl-wt/wt-3';
/** A close code no pane rule names: the connection dropped. */
const ABNORMAL_CLOSE = 1006;
const SHELL: PaneTarget = { run: 'shell', folder: WORKTREE };

type Opened = { store: PaneStore; daemon: FakeDaemon; key: string };

function openPane(target: PaneTarget): Opened {
  const daemon = new FakeDaemon();
  const store = new PaneStore(daemon, daemon.fakeTerminal);
  const key = store.open(PROJECT, target);
  return { store, daemon, key };
}

/** A pane attached to the page: its terminal fitted and its one socket open. */
function attachedPane(target: PaneTarget): Opened & { socket: FakeSocket; terminal: FakeTerminal } {
  const opened = openPane(target);
  opened.store.showAndConnect(opened.key, document.createElement('div'));
  return { ...opened, socket: onlyOne(opened.daemon.sockets), terminal: onlyOne(opened.daemon.terminals) };
}

/** An attached pane the daemon started: what every accepted pane is once its first frame arrived. */
function livePane(): Opened & { socket: FakeSocket; terminal: FakeTerminal } {
  const attached = attachedPane(SHELL);
  attached.socket.receive({ type: 'started', pane: 'pane-1', command: ['/bin/zsh', '-l'], folder: WORKTREE });
  return attached;
}

function onlyOne<T>(values: readonly T[]): T {
  const [first] = values;
  if (first === undefined) throw new Error('the pane opened nothing');
  return first;
}

function view(store: PaneStore, key: string): PaneView {
  const found = store.panes().find((pane) => pane.key === key);
  if (found === undefined) throw new Error(`no pane ${key} in the store`);
  return found;
}

function textFrames(socket: FakeSocket): unknown[] {
  return socket.sent.filter((frame): frame is string => typeof frame === 'string').map((frame) => JSON.parse(frame) as unknown);
}

function binaryFrames(socket: FakeSocket): Uint8Array[] {
  return socket.sent.filter((frame): frame is Uint8Array => typeof frame !== 'string').map((frame) => Uint8Array.from(frame));
}

/** Text as bytes of this realm, so a binary frame is told from a text one. */
function encoded(text: string): Uint8Array {
  return Uint8Array.from(new TextEncoder().encode(text));
}

function bytesOf(count: number): Uint8Array {
  return new Uint8Array(count).fill(0x61);
}

test('Attach_OpensOneSocketForTheFolderRunAndFittedSize', () => {
  const opened = openPane(SHELL);
  opened.store.showAndConnect(opened.key, document.createElement('div'));
  const requests = opened.daemon.sockets.map((socket) => {
    const url = new URL(socket.path, 'http://page.test');
    return { route: url.pathname, path: url.searchParams.get('path'), run: url.searchParams.get('run'), cols: url.searchParams.get('cols'), rows: url.searchParams.get('rows') };
  });
  expect(requests, 'because the daemon plans the pane from the folder and run in the query and starts it at the size the terminal fits to')
    .toEqual([{ route: `/api/projects/${PROJECT}/panes`, path: WORKTREE, run: 'shell', cols: String(FAKE_TERMINAL_SIZE.columns), rows: String(FAKE_TERMINAL_SIZE.rows) }]);
});

test('Open_BeforeAttach_OpensNoSocket', () => {
  const { daemon } = openPane(SHELL);
  expect(daemon.sockets.length, 'because the socket waits for a fitted terminal so the process starts at the right size').toBe(0);
});

test('SecondAttach_OpensNoSecondSocket', () => {
  const { store, daemon, key } = attachedPane(SHELL);
  store.showAndConnect(key, document.createElement('div'));
  expect(daemon.sockets.length, 'because showing a pane again must not start a second process').toBe(1);
});

test('OutputFromTheDaemon_IsWrittenToTheTerminal', () => {
  const { socket, terminal } = livePane();
  const output = encoded('total 42\r\n');
  socket.receive(output);
  expect(terminal.written, 'because the bytes the pty printed are what the terminal draws').toEqual([output]);
});

test('Typing_IsSentAsABinaryFrame', () => {
  const { socket, terminal } = livePane();
  terminal.type('git status\r');
  expect(binaryFrames(socket), 'because keystrokes go to the pty as raw bytes, not as a text control').toEqual([encoded('git status\r')]);
});

test('DrawnBelowAckEvery_SendsNoAck', () => {
  const { socket } = livePane();
  socket.receive(bytesOf(ACK_EVERY_BYTES - 1));
  expect(textFrames(socket).filter((frame) => (frame as { type: string }).type === 'ack'), 'because the page acks in steps, not on every write').toEqual([]);
});

test('DrawnReachingAckEvery_SendsAnAckForWhatWasDrawn', () => {
  const { socket } = livePane();
  socket.receive(bytesOf(ACK_EVERY_BYTES - 1));
  socket.receive(bytesOf(1));
  expect(textFrames(socket).filter((frame) => (frame as { type: string }).type === 'ack'), 'because the daemon resumes a paused pty only when the page says it drew the bytes')
    .toEqual([{ type: 'ack', bytes: ACK_EVERY_BYTES }]);
});

test('Refit_SendsResizeWithTheNewSize', () => {
  const { store, key, socket, terminal } = livePane();
  terminal.size = { columns: 61, rows: 19 };
  store.refit(key);
  expect(textFrames(socket).at(-1), 'because the pty must learn the size the terminal now has').toEqual({ type: 'resize', cols: 61, rows: 19 });
});

test('Started_MakesThePaneLive', () => {
  const { store, key, socket } = attachedPane(SHELL);
  socket.receive({ type: 'started', pane: 'pane-7', command: ['/bin/zsh', '-l'], folder: WORKTREE });
  expect(view(store, key).state, 'because the daemon started the process').toBe('live');
});

test('Started_KeepsTheCommandTheDaemonRan', () => {
  const { store, key, socket } = attachedPane(SHELL);
  socket.receive({ type: 'started', pane: 'pane-7', command: ['/usr/local/bin/claude', '--model', 'opus'], folder: WORKTREE });
  expect(view(store, key).command, 'because the tab says what the daemon actually runs').toEqual(['/usr/local/bin/claude', '--model', 'opus']);
});

type Ending = { how: string; notice: PaneNotice | null; code: number; words: RegExp };

const ENDINGS: Ending[] = [
  { how: 'exit', notice: { type: 'exit', code: 3, signal: null }, code: PANE_CLOSE.ended, words: new RegExp(`${PANE_END_WORDS.sessionEnded}.*3`) },
  { how: 'refused', notice: { type: 'refused', error: '/tmp/elsewhere is not a folder of this project' }, code: PANE_CLOSE.refused, words: /\/tmp\/elsewhere is not a folder of this project/ },
  { how: 'daemon stopping', notice: null, code: PANE_CLOSE.daemonStopping, words: new RegExp(PANE_END_WORDS.daemonStopped) },
  { how: 'project gone', notice: null, code: PANE_CLOSE.projectGone, words: new RegExp(PANE_END_WORDS.projectGone) },
  { how: 'connection lost', notice: null, code: ABNORMAL_CLOSE, words: new RegExp(PANE_END_WORDS.connectionLost) },
];

test.each(ENDINGS)('DaemonEndsThePane_SaysWhy ($how)', ({ notice, code, words }) => {
  const { store, key, socket } = attachedPane(SHELL);
  if (notice !== null) socket.receive(notice);
  socket.closeFromDaemon(code);
  expect(view(store, key).ended ?? '', 'because an ended pane tells the owner how it ended').toMatch(words);
});

test('DaemonEndsThePane_KeepsItAsEnded', () => {
  const { store, key, socket } = attachedPane(SHELL);
  socket.receive({ type: 'exit', code: 0, signal: null });
  socket.closeFromDaemon(PANE_CLOSE.ended);
  expect(view(store, key).state, 'because the scrollback stays readable until the owner closes the tab').toBe('ended');
});

test('Close_ClosesTheSocketAsEnded', () => {
  const { store, key, socket } = attachedPane(SHELL);
  store.close(key);
  expect(socket.closedWith, 'because closing the pane ends its process on the daemon').toBe(PANE_CLOSE.ended);
});

test('Close_DropsThePane', () => {
  const { store, key } = attachedPane(SHELL);
  store.close(key);
  expect(store.panes().map((pane) => pane.key), 'because a closed pane leaves the dock').toEqual([]);
});

type Refit = { how: string; resizedTo: { columns: number; rows: number }[] };

const UNCHANGED_REFITS: Refit[] = [
  { how: 'the opening size', resizedTo: [] },
  { how: 'a size already sent', resizedTo: [{ columns: 61, rows: 19 }] },
];

test.each(UNCHANGED_REFITS)('Refit_SameSizeAgain_SendsNoResize ($how)', ({ resizedTo }) => {
  const { store, key, socket, terminal } = livePane();
  for (const size of resizedTo) { terminal.size = size; store.refit(key); }
  store.refit(key);
  const resizes = textFrames(socket).filter((frame) => (frame as { type: string }).type === 'resize');
  expect(resizes, 'because the pty already has this size, so the daemon hears each size once')
    .toEqual(resizedTo.map((size) => ({ type: 'resize', cols: size.columns, rows: size.rows })));
});

type Malformed = { what: string; notice: unknown };

const MALFORMED_NOTICES: Malformed[] = [
  { what: 'a started whose command is not a list of words', notice: { type: 'started', pane: 'pane-1', command: '/bin/zsh -l', folder: WORKTREE } },
  { what: 'an exit whose code is not a whole number', notice: { type: 'exit', code: 1.5, signal: null } },
  { what: 'a refused with no error', notice: { type: 'refused' } },
];

test.each(MALFORMED_NOTICES)('MalformedNotice_Ignored ($what)', ({ notice }) => {
  const { store, key, socket } = attachedPane(SHELL);
  const before = structuredClone(view(store, key));
  socket.receive(notice as PaneNotice);
  expect(view(store, key), 'because a frame the page cannot trust must not change what the pane shows').toEqual(before);
});
