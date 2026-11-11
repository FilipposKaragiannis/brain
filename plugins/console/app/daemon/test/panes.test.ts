import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setImmediate as tick } from 'node:timers/promises';
import { silentLogger } from '../src/log.ts';
import type { PaneFacts, PaneHost, PaneRequest } from '../src/panePlan.ts';
import type { PaneControl, PaneNotice } from '../src/paneProtocol.ts';
import { MAX_PANES, OUTPUT_HIGH_WATER_BYTES, OUTPUT_LOW_WATER_BYTES, PANE_CLOSE, PANE_KILL_GRACE_MS } from '../src/paneProtocol.ts';
import { PaneSessions } from '../src/panes.ts';
import type { PaneLink } from '../src/panes.ts';
import { fakePty } from './fakePty.ts';
import type { FakePty } from './fakePty.ts';
import { fakeScheduler } from './fakeSpawner.ts';

const PROJECT = { id: 'app', root: '/p/app' };
const OTHER_PROJECT = { id: 'site', root: '/p/site' };
const NO_PAIR = { model: null, effort: null, from: 'jobs' };
const FACTS: PaneFacts = { folders: ['/p/app', '/p/app-wt-2', '/p/site'], pairs: { claude: NO_PAIR, codex: NO_PAIR } };
const HOST: PaneHost = { shell: '/bin/zsh', environment: { PATH: '/usr/bin' }, isFolder: () => true, executable: () => null };
const SHELL_AT_ROOT: PaneRequest = { folder: '/p/app', run: 'shell', size: { columns: 120, rows: 33 } };

type FakeLink = {
  link: PaneLink;
  /** Every chunk of output the link carried, in order. */
  output: Uint8Array[];
  notices: PaneNotice[];
  /** The close code, or null while the link is open. */
  ended: number | null;
  type(bytes: Uint8Array): void;
  control(control: PaneControl): void;
  go(): void;
};

function fakeLink(): FakeLink {
  let input: (bytes: Uint8Array) => void = () => {};
  let control: (control: PaneControl) => void = () => {};
  let gone: () => void = () => {};
  const fake: FakeLink = {
    output: [], notices: [], ended: null,
    link: {
      output: (bytes) => { fake.output.push(bytes); },
      tell: (notice) => { fake.notices.push(notice); },
      end: (code) => { fake.ended = code; },
      onInput: (listener) => { input = listener; },
      onControl: (listener) => { control = listener; },
      onGone: (listener) => { gone = listener; },
      queuedBytes: () => 0,
    },
    type: (bytes) => input(bytes),
    control: (sent) => control(sent),
    go: () => gone(),
  };
  return fake;
}

function sessions(refusal: string | null) {
  const { spawner, ptys } = fakePty(refusal);
  const timers = fakeScheduler();
  const panes = new PaneSessions({ spawner, host: HOST, scheduler: timers.scheduler, log: silentLogger });
  const open = (request: PaneRequest = SHELL_AT_ROOT, project = PROJECT): FakeLink => {
    const link = fakeLink();
    panes.open(project, request, FACTS, link.link);
    return link;
  };
  return { panes, ptys, timers, open };
}

/** The one pty a test opened; a missing one throws on first use. */
function only(ptys: FakePty[]): FakePty {
  return ptys[0]!;
}

const bytes = (text: string): Uint8Array => new TextEncoder().encode(text);
const filler = (length: number): Uint8Array => new Uint8Array(length).fill(0x61);

test('ListedFolder_Started_TellsItsCommandFirst', () => {
  const { open } = sessions(null);
  const link = open();
  const told = link.notices.map((notice) => (notice.type === 'started' ? { type: notice.type, command: notice.command, folder: notice.folder } : notice));
  assert.deepEqual(told, [{ type: 'started', command: ['/bin/zsh', '-l'], folder: '/p/app' }], 'because the page shows what runs before any output');
});

test('ListedFolder_PtySpawnedAtTheRequestedSizeAndFolder', () => {
  const { open, ptys } = sessions(null);
  open();
  const pty = only(ptys);
  assert.deepEqual([pty.launch.workingFolder, pty.size], ['/p/app', { columns: 120, rows: 33 }], 'because a TUI paints its first screen at the size the page measured');
});

test('Pane_SpawnEnvironment_IsTheHostsEnvironment', () => {
  const { open, ptys } = sessions(null);
  open();
  assert.deepEqual(only(ptys).environment, HOST.environment, 'because every pane gets the filtered environment, nothing more');
});

test('PtyOutput_ReachesTheLink', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  only(ptys).emit(bytes('owner@mac app % '));
  assert.equal(new TextDecoder().decode(Buffer.concat(link.output)), 'owner@mac app % ', 'because what the shell prints is what the page draws');
});

test('LinkInput_ReachesThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  link.type(bytes('ls -la\r'));
  assert.equal(new TextDecoder().decode(Buffer.concat(only(ptys).received)), 'ls -la\r', 'because what the owner types goes to the shell');
});

test('ResizeControl_ResizesThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  link.control({ type: 'resize', cols: 97, rows: 51 });
  assert.deepEqual(only(ptys).size, { columns: 97, rows: 51 }, 'because the pane follows the page\'s terminal size');
});

test('UnlistedFolder_RefusedAndEnded4400', () => {
  const { open } = sessions(null);
  const link = open({ ...SHELL_AT_ROOT, folder: '/etc' });
  assert.deepEqual([link.notices.map((notice) => notice.type), link.ended], [['refused'], PANE_CLOSE.refused], 'because a folder the snapshot does not list gets only a refusal');
});

test('UnlistedFolder_NoPtySpawned', () => {
  const { open, ptys } = sessions(null);
  open({ ...SHELL_AT_ROOT, folder: '/etc' });
  assert.equal(ptys.length, 0, 'because a refused folder never starts a process');
});

test('SpawnerRefusal_ReasonToldAndEnded4400', () => {
  const { open } = sessions('posix_spawnp failed');
  const link = open();
  assert.deepEqual([link.notices, link.ended], [[{ type: 'refused', error: 'posix_spawnp failed' }], PANE_CLOSE.refused], 'because a pty that cannot start is a refusal with its reason, and the daemon runs on');
});

test('ProcessExit_ToldThenEnded1000', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  only(ptys).exit(3, null);
  assert.deepEqual([link.notices.at(-1), link.ended], [{ type: 'exit', code: 3, signal: null }, PANE_CLOSE.ended], 'because the page says how the process ended, then the pane closes');
});

test('LinkGone_HangsUpThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  link.go();
  assert.deepEqual(only(ptys).signals, ['SIGHUP'], 'because a closed terminal hangs up its processes, as any terminal does');
});

test('LinkGone_ProcessIgnoringHangUp_KilledOnlyAfterTheGrace', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open();
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  const beforeGrace = [...pty.signals];
  timers.fire(PANE_KILL_GRACE_MS);
  assert.deepEqual([beforeGrace, pty.signals], [['SIGHUP'], ['SIGHUP', 'SIGKILL']], 'because a process that ignores the hang-up gets the grace, then is killed');
});

test('LinkGone_AfterTheGrace_MasterClosed', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open();
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  timers.fire(PANE_KILL_GRACE_MS);
  assert.equal(pty.closed, true, 'because closing the master hangs up whatever still holds the terminal');
});

test('StopAll_EveryLinkEnded1001', async () => {
  const { panes, open } = sessions(null);
  const links = [open(), open({ ...SHELL_AT_ROOT, folder: '/p/app-wt-2' })];
  await panes.stopAll();
  assert.deepEqual(links.map((link) => link.ended), [PANE_CLOSE.daemonStopping, PANE_CLOSE.daemonStopping], 'because a stopping daemon tells every page why its pane ends');
});

test('StopAll_ProcessIgnoringHangUp_SettlesOnlyOnceItIsKilled', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open();
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  let settled = false;
  const stopping = panes.stopAll().then(() => { settled = true; });
  await tick();
  const settledBeforeGrace = settled;
  timers.fire(PANE_KILL_GRACE_MS);
  await stopping;
  assert.deepEqual([settledBeforeGrace, pty.exited], [false, true], 'because the daemon exits only after every pane\'s process has ended');
});

test('PaneLimit_OneMoreThanTheLimit_Refused', () => {
  const { open } = sessions(null);
  for (let opened = 0; opened < MAX_PANES; opened += 1) open();
  const extra = open();
  assert.deepEqual([extra.notices.map((notice) => notice.type), extra.ended], [['refused'], PANE_CLOSE.refused], 'because the daemon runs at most MAX_PANES panes across every project');
});

test('PaneLimit_LimitAcrossProjects_Refused', () => {
  const { open } = sessions(null);
  for (let opened = 0; opened < MAX_PANES; opened += 1) open();
  const extra = open({ ...SHELL_AT_ROOT, folder: '/p/site' }, OTHER_PROJECT);
  assert.equal(extra.ended, PANE_CLOSE.refused, 'because the limit is the machine\'s, not one project\'s');
});

test('PaneLimit_OneClosed_ANewOneOpens', () => {
  const { open, ptys } = sessions(null);
  for (let opened = 0; opened < MAX_PANES; opened += 1) open();
  ptys[0]!.exit(0, null);
  const next = open();
  assert.deepEqual(next.notices.map((notice) => notice.type), ['started'], 'because a pane that ended frees its place');
});

test('Output_AtTheHighWater_PtyRunsOn', () => {
  const { open, ptys } = sessions(null);
  open();
  const pty = only(ptys);
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES));
  assert.equal(pty.paused, false, 'because the pty pauses only above the high water');
});

test('Output_PastTheHighWater_PtyPaused', () => {
  const { open, ptys } = sessions(null);
  open();
  const pty = only(ptys);
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES));
  pty.emit(filler(1));
  assert.equal(pty.paused, true, 'because a page that has not drawn a megabyte must not be flooded further');
});

test('Ack_UnderTheLowWater_PtyResumed', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  const pty = only(ptys);
  const sent = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(sent));
  link.control({ type: 'ack', bytes: sent - OUTPUT_LOW_WATER_BYTES + 1 });
  assert.equal(pty.paused, false, 'because the page has caught up to under the low water');
});

test('Ack_StillAboveTheLowWater_PtyStaysPaused', () => {
  const { open, ptys } = sessions(null);
  const link = open();
  const pty = only(ptys);
  const sent = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(sent));
  link.control({ type: 'ack', bytes: sent - OUTPUT_LOW_WATER_BYTES - 1 });
  assert.equal(pty.paused, true, 'because the page is still behind by more than the low water');
});

test('EndProject_ItsPanesEnded4404', () => {
  const { panes, open } = sessions(null);
  const link = open();
  panes.endProject(PROJECT.id);
  assert.equal(link.ended, PANE_CLOSE.projectGone, 'because the page says the project is no longer watched');
});

test('EndProject_ItsPtyHungUp', () => {
  const { panes, open, ptys } = sessions(null);
  open();
  panes.endProject(PROJECT.id);
  assert.deepEqual(only(ptys).signals, ['SIGHUP'], 'because a pane of a project that went ends as a lost link does');
});

test('EndProject_AnotherProjectsPane_StaysOpen', () => {
  const { panes, open } = sessions(null);
  open();
  const other = open({ ...SHELL_AT_ROOT, folder: '/p/site' }, OTHER_PROJECT);
  panes.endProject(PROJECT.id);
  assert.equal(other.ended, null, 'because only the project that went loses its panes');
});
