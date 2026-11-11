import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setImmediate as tick } from 'node:timers/promises';
import { silentLogger } from '../src/log.ts';
import type { PaneFacts, PaneHost, PaneRequest } from '../src/panePlan.ts';
import type { PaneControl, PaneNotice } from '../src/paneProtocol.ts';
import { MAX_PANES, OUTPUT_HIGH_WATER_BYTES, OUTPUT_LOW_WATER_BYTES, PANE_CLOSE, PANE_KILL_GRACE_MS, PAUSED_EXIT_CHECK_MS } from '../src/paneProtocol.ts';
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
  /** Bytes the socket holds, not yet written to the network. */
  queued: number;
  type(bytes: Uint8Array): void;
  control(control: PaneControl): void;
  go(): void;
};

function fakeLink(): FakeLink {
  let input: (bytes: Uint8Array) => void = () => {};
  let control: (control: PaneControl) => void = () => {};
  let gone: () => void = () => {};
  const fake: FakeLink = {
    output: [], notices: [], ended: null, queued: 0,
    link: {
      output: (bytes) => { fake.output.push(bytes); },
      tell: (notice) => { fake.notices.push(notice); },
      end: (code) => { fake.ended = code; },
      onInput: (listener) => { input = listener; },
      onControl: (listener) => { control = listener; },
      onGone: (listener) => { gone = listener; },
      queuedBytes: () => fake.queued,
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
  const open = (request: PaneRequest, project: { id: string; root: string }): FakeLink => {
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
  const link = open(SHELL_AT_ROOT, PROJECT);
  const told = link.notices.map((notice) => (notice.type === 'started' ? { type: notice.type, command: notice.command, folder: notice.folder } : notice));
  assert.deepEqual(told, [{ type: 'started', command: ['/bin/zsh', '-l'], folder: '/p/app' }], 'because the page shows what runs before any output');
});

test('ListedFolder_PtySpawnedAtTheRequestedSizeAndFolder', () => {
  const { open, ptys } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  assert.deepEqual([pty.launch.workingFolder, pty.size], ['/p/app', { columns: 120, rows: 33 }], 'because a TUI paints its first screen at the size the page measured');
});

test('Pane_SpawnEnvironment_IsTheHostsEnvironment', () => {
  const { open, ptys } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual(only(ptys).environment, HOST.environment, 'because every pane gets the filtered environment, nothing more');
});

test('PtyOutput_ReachesTheLink', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  only(ptys).emit(bytes('owner@mac app % '));
  assert.equal(new TextDecoder().decode(Buffer.concat(link.output)), 'owner@mac app % ', 'because what the shell prints is what the page draws');
});

test('LinkInput_ReachesThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  link.type(bytes('ls -la\r'));
  assert.equal(new TextDecoder().decode(Buffer.concat(only(ptys).received)), 'ls -la\r', 'because what the owner types goes to the shell');
});

test('ResizeControl_ResizesThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  link.control({ type: 'resize', cols: 97, rows: 51 });
  assert.deepEqual(only(ptys).size, { columns: 97, rows: 51 }, 'because the pane follows the page\'s terminal size');
});

test('UnlistedFolder_RefusedAndEnded4400', () => {
  const { open } = sessions(null);
  const link = open({ ...SHELL_AT_ROOT, folder: '/etc' }, PROJECT);
  assert.deepEqual([link.notices.map((notice) => notice.type), link.ended], [['refused'], PANE_CLOSE.refused], 'because a folder the snapshot does not list gets only a refusal');
});

test('UnlistedFolder_NoPtySpawned', () => {
  const { open, ptys } = sessions(null);
  open({ ...SHELL_AT_ROOT, folder: '/etc' }, PROJECT);
  assert.equal(ptys.length, 0, 'because a refused folder never starts a process');
});

test('SpawnerRefusal_ReasonToldAndEnded4400', () => {
  const { open } = sessions('posix_spawnp failed');
  const link = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual([link.notices, link.ended], [[{ type: 'refused', error: 'posix_spawnp failed' }], PANE_CLOSE.refused], 'because a pty that cannot start is a refusal with its reason, and the daemon runs on');
});

test('ProcessExit_ToldThenEnded1000', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  only(ptys).exit(3, null);
  assert.deepEqual([link.notices.at(-1), link.ended], [{ type: 'exit', code: 3, signal: null }, PANE_CLOSE.ended], 'because the page says how the process ended, then the pane closes');
});

test('LinkGone_HangsUpThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  link.go();
  assert.equal(only(ptys).exited, true, 'because a closed terminal hangs up its processes, as any terminal does, before any kill grace runs out');
});

test('LinkGone_ProcessIgnoringHangUp_KilledOnlyAfterTheGrace', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  const beforeGrace = [...pty.signals];
  timers.fire(PANE_KILL_GRACE_MS);
  assert.deepEqual([beforeGrace, pty.signals], [['SIGHUP'], ['SIGHUP', 'SIGKILL']], 'because a process that ignores the hang-up gets the grace, then is killed');
});

test('LinkGone_AfterTheGrace_MasterClosed', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  timers.fire(PANE_KILL_GRACE_MS);
  assert.equal(pty.closed, true, 'because closing the master hangs up whatever still holds the terminal');
});

test('StopAll_EveryLinkEnded1001', async () => {
  const { panes, open } = sessions(null);
  const links = [open(SHELL_AT_ROOT, PROJECT), open({ ...SHELL_AT_ROOT, folder: '/p/app-wt-2' }, PROJECT)];
  await panes.stopAll();
  assert.deepEqual(links.map((link) => link.ended), [PANE_CLOSE.daemonStopping, PANE_CLOSE.daemonStopping], 'because a stopping daemon tells every page why its pane ends');
});

test('StopAll_ProcessIgnoringHangUp_SettlesOnlyOnceItIsKilled', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
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
  for (let opened = 0; opened < MAX_PANES; opened += 1) open(SHELL_AT_ROOT, PROJECT);
  const extra = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual([extra.notices.map((notice) => notice.type), extra.ended], [['refused'], PANE_CLOSE.refused], 'because the daemon runs at most MAX_PANES panes across every project');
});

test('PaneLimit_LimitAcrossProjects_Refused', () => {
  const { open } = sessions(null);
  for (let opened = 0; opened < MAX_PANES; opened += 1) open(SHELL_AT_ROOT, PROJECT);
  const extra = open({ ...SHELL_AT_ROOT, folder: '/p/site' }, OTHER_PROJECT);
  assert.equal(extra.ended, PANE_CLOSE.refused, 'because the limit is the machine\'s, not one project\'s');
});

test('PaneLimit_OneClosed_ANewOneOpens', () => {
  const { open, ptys } = sessions(null);
  for (let opened = 0; opened < MAX_PANES; opened += 1) open(SHELL_AT_ROOT, PROJECT);
  ptys[0]!.exit(0, null);
  const next = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual(next.notices.map((notice) => notice.type), ['started'], 'because a pane that ended frees its place');
});

test('Output_AtTheHighWater_PtyRunsOn', () => {
  const { open, ptys } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES));
  assert.equal(pty.paused, false, 'because the pty pauses only above the high water');
});

test('Output_PastTheHighWater_PtyPaused', () => {
  const { open, ptys } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES));
  pty.emit(filler(1));
  assert.equal(pty.paused, true, 'because a page that has not drawn a megabyte must not be flooded further');
});

test('Ack_UnderTheLowWater_PtyResumed', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  const sent = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(sent));
  link.control({ type: 'ack', bytes: sent - OUTPUT_LOW_WATER_BYTES + 1 });
  assert.equal(pty.paused, false, 'because the page has caught up to under the low water');
});

test('Ack_StillAboveTheLowWater_PtyStaysPaused', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  const sent = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(sent));
  link.control({ type: 'ack', bytes: sent - OUTPUT_LOW_WATER_BYTES - 1 });
  assert.equal(pty.paused, true, 'because the page is still behind by more than the low water');
});

test('EndProject_ItsPanesEnded4404', () => {
  const { panes, open } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  panes.endProject(PROJECT.id);
  assert.equal(link.ended, PANE_CLOSE.projectGone, 'because the page says the project is no longer watched');
});

test('EndProject_ItsPtyHungUp', () => {
  const { panes, open, ptys } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  panes.endProject(PROJECT.id);
  assert.equal(only(ptys).exited, true, 'because a pane of a project that went ends its process as a lost link does');
});

test('EndProject_AnotherProjectsPane_StaysOpen', () => {
  const { panes, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const other = open({ ...SHELL_AT_ROOT, folder: '/p/site' }, OTHER_PROJECT);
  panes.endProject(PROJECT.id);
  assert.equal(other.ended, null, 'because only the project that went loses its panes');
});

test('Ack_ForMoreThanWasSent_BanksNoCreditForLaterOutput', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  link.control({ type: 'ack', bytes: Number.MAX_SAFE_INTEGER });
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES + 1));
  assert.equal(pty.paused, true, 'because an ack for bytes never sent must not let a page that reads nothing flood the daemon');
});

test('Output_LinkQueuePastTheHighWater_PtyPausedThoughAllIsAcked', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  link.queued = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(17));
  link.control({ type: 'ack', bytes: 17 });
  assert.equal(pty.paused, true, 'because bytes the socket still holds are bytes the page has not read, whatever it acked');
});

test('Ack_LinkQueueAtTheLowWater_PtyStaysPaused', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  link.queued = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(17));
  link.queued = OUTPUT_LOW_WATER_BYTES;
  link.control({ type: 'ack', bytes: 17 });
  assert.equal(pty.paused, true, 'because the pty resumes only once the socket\'s queue is under the low water');
});

test('Ack_LinkQueueUnderTheLowWater_PtyResumed', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  link.queued = OUTPUT_HIGH_WATER_BYTES + 1;
  pty.emit(filler(17));
  link.queued = OUTPUT_LOW_WATER_BYTES - 1;
  link.control({ type: 'ack', bytes: 17 });
  assert.equal(pty.paused, false, 'because a drained socket and a page that caught up let the output flow again');
});

test('PaneLimit_HungUpPaneStillRunning_CountsAgainstTheLimit', () => {
  const { open, ptys } = sessions(null);
  const links = Array.from({ length: MAX_PANES }, () => open(SHELL_AT_ROOT, PROJECT));
  ptys[0]!.ignoresHangUp = true;
  links[0]!.go();
  const extra = open(SHELL_AT_ROOT, PROJECT);
  assert.equal(extra.ended, PANE_CLOSE.refused, 'because a closed pane whose process still runs is still a process the daemon holds');
});

test('PaneLimit_HungUpPaneKilledAfterTheGrace_ANewOneOpens', () => {
  const { open, ptys, timers } = sessions(null);
  const links = Array.from({ length: MAX_PANES }, () => open(SHELL_AT_ROOT, PROJECT));
  ptys[0]!.ignoresHangUp = true;
  links[0]!.go();
  timers.fire(PANE_KILL_GRACE_MS);
  const next = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual(next.notices.map((notice) => notice.type), ['started'], 'because a pane frees its place once its process has ended');
});

test('LinkGone_WhilePaused_PtyResumed', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES + 1));
  link.go();
  assert.equal(pty.paused, false, 'because a paused pty never reads the hung-up process\'s end, so it would wait out the whole grace');
});

/** A pane whose pty the output flow paused: more unacked output than the high water. */
function pausedPane() {
  const opened = sessions(null);
  const link = opened.open(SHELL_AT_ROOT, PROJECT);
  const pty = only(opened.ptys);
  pty.emit(filler(OUTPUT_HIGH_WATER_BYTES + 1));
  return { ...opened, link, pty };
}

const LAST_WORDS = 'error: the session ran out of context\r\n';

test('ProcessEndsWhilePaused_ItsLastOutputReachesTheLink', () => {
  const { link, pty, timers } = pausedPane();
  pty.finish([bytes(LAST_WORDS)], 1);
  timers.fire(PAUSED_EXIT_CHECK_MS);
  assert.equal(new TextDecoder().decode(link.output.at(-1)), LAST_WORDS, 'because a crashing agent\'s last line is what the owner most needs to read, paused or not');
});

test('ProcessEndsWhilePaused_ExitTold', () => {
  const { link, pty, timers } = pausedPane();
  pty.finish([bytes(LAST_WORDS)], 1);
  timers.fire(PAUSED_EXIT_CHECK_MS);
  assert.deepEqual(link.notices.at(-1), { type: 'exit', code: 1, signal: null }, 'because the page says how the session ended even when it ended while paused');
});

test('ProcessStillRunningWhilePaused_PtyStaysPaused', () => {
  const { pty, timers } = pausedPane();
  timers.fire(PAUSED_EXIT_CHECK_MS);
  assert.equal(pty.paused, true, 'because a live process stays paused until the page catches up');
});

test('ProcessEndsWhilePaused_TailPastTheHighWater_ExitStillTold', () => {
  const { link, pty, timers } = pausedPane();
  pty.finish([filler(OUTPUT_HIGH_WATER_BYTES + 1), filler(OUTPUT_HIGH_WATER_BYTES + 1)], 2);
  timers.fire(PAUSED_EXIT_CHECK_MS);
  assert.deepEqual(link.notices.at(-1), { type: 'exit', code: 2, signal: null }, 'because once the process is gone, pausing again only stalls the tail it left');
});

test('PausedPaneEnds_NoExitCheckLeftBehind', () => {
  const { pty, timers } = pausedPane();
  pty.exit(0, null);
  assert.deepEqual(timers.pending().filter((ms) => ms === PAUSED_EXIT_CHECK_MS), [], 'because a pane that ended must not keep a timer polling a pid the system may reuse');
});

test('PausedPaneResumed_NoExitCheckLeftBehind', () => {
  const { link, timers } = pausedPane();
  link.control({ type: 'ack', bytes: OUTPUT_HIGH_WATER_BYTES + 1 });
  assert.deepEqual(timers.pending().filter((ms) => ms === PAUSED_EXIT_CHECK_MS), [], 'because a pty that reads on needs no check for an exit it will read itself');
});
