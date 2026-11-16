import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setImmediate as tick } from 'node:timers/promises';
import { MAXIMUM_PANES, PANE_CLOSE, PANE_KILL_GRACE_MILLISECONDS } from '../src/paneProtocol.ts';
import type { PtySpawner } from '../src/panes.ts';
import { fakePty } from './fakePty.ts';
import type { FakePty } from './fakePty.ts';
import { bytes, HOST, only, OTHER_PROJECT, PROJECT, sessions, sessionsOver, SHELL_AT_ROOT } from './paneSessionsRig.ts';

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
  const link = open({ ...SHELL_AT_ROOT, target: { run: 'shell', folder: '/etc' } }, PROJECT);
  assert.deepEqual([link.notices.map((notice) => notice.type), link.ended], [['refused'], PANE_CLOSE.refused], 'because a folder the snapshot does not list gets only a refusal');
});

test('UnlistedFolder_NoPtySpawned', () => {
  const { open, ptys } = sessions(null);
  open({ ...SHELL_AT_ROOT, target: { run: 'shell', folder: '/etc' } }, PROJECT);
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

test('LinkGone_ProcessIgnoringHangUp_StillRunningBeforeTheGrace', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  assert.equal(pty.exited, false, 'because a process that ignores the hang-up gets the whole grace before any kill');
});

test('LinkGone_ProcessIgnoringHangUp_KilledOnceTheGraceRunsOut', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  assert.equal(pty.exited, true, 'because a process that outlives the grace is killed, so a closed pane leaves nothing running');
});

test('LinkGone_AfterTheGrace_MasterClosed', async () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await tick();
  assert.equal(pty.closed, true, 'because closing the master hangs up whatever still holds the terminal');
});

test('StopAll_EveryLinkEnded1001', async () => {
  const { panes, open } = sessions(null);
  const links = [open(SHELL_AT_ROOT, PROJECT), open({ ...SHELL_AT_ROOT, target: { run: 'shell', folder: '/p/app-wt-2' } }, PROJECT)];
  await panes.stopAll();
  assert.deepEqual(links.map((link) => link.ended), [PANE_CLOSE.daemonStopping, PANE_CLOSE.daemonStopping], 'because a stopping daemon tells every page why its pane ends');
});

test('StopAll_ProcessIgnoringHangUp_NotSettledBeforeTheGrace', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  only(ptys).ignoresHangUp = true;
  let settled = false;
  const stopping = panes.stopAll().then(() => { settled = true; });
  await tick();
  const settledBeforeGrace = settled;
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.equal(settledBeforeGrace, false, 'because the daemon waits for a process that ignores the hang-up instead of exiting under it');
});

test('StopAll_ProcessIgnoringHangUp_SettlesWithTheProcessKilled', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  const stopping = panes.stopAll();
  await tick();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.equal(pty.exited, true, 'because the daemon exits only after every pane\'s process has ended');
});

/** The ways a pane is closed while the daemon runs on: the owner's Close or a lost page drop the link, and a project that goes ends its panes. */
const CLOSINGS: { how: string; close(panes: ReturnType<typeof sessions>['panes'], link: { go(): void }): void }[] = [
  { how: 'the link gone', close: (_panes, link) => link.go() },
  { how: 'the project gone', close: (panes) => panes.endProject(PROJECT.id) },
];

test('PaneClosed_ChildIgnoringHangUpOutlivesItsProcess_GroupKilledOnceTheGraceRunsOut', () => {
  for (const closing of CLOSINGS) {
    const { panes, open, ptys, timers } = sessions(null);
    const link = open(SHELL_AT_ROOT, PROJECT);
    const pty = only(ptys);
    pty.childIgnoresHangUp = true;
    closing.close(panes, link);
    timers.fire(PANE_KILL_GRACE_MILLISECONDS);
    assert.equal(pty.groupRunning(), false, `because with ${closing.how} a process left in the pane's group after its own process died on the hang-up is killed, so a closed pane leaves nothing running`);
  }
});

test('LinkGone_GroupEmptyWhenTheProcessExits_NoTimerLeft', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  only(ptys);
  link.go();
  assert.deepEqual(timers.pending(), [], 'because a group with nothing left in it needs no kill, so its grace is cancelled');
});

test('LinkGone_GroupEmptyWhenTheProcessExits_SomeoneElsesProcessGivenItsIdKeepsRunning', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  link.go();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  assert.equal(pty.someoneElsesProcessRunning, true, 'because an emptied group\'s id may be handed to someone else\'s processes, so it is never signalled again');
});

test('LinkGone_GroupEmptiesByItselfDuringTheGrace_SomeoneElsesProcessGivenItsIdKeepsRunning', () => {
  const { open, ptys, timers } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.childIgnoresHangUp = true;
  link.go();
  pty.childEnded = true;
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  assert.equal(pty.someoneElsesProcessRunning, true, 'because a group that emptied during the grace may have its id handed to someone else\'s processes, so it is never signalled');
});

test('StopAll_GroupEmptiesByItselfDuringTheGrace_Settles', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.childIgnoresHangUp = true;
  let settled = false;
  void panes.stopAll().then(() => { settled = true; });
  await tick();
  pty.childEnded = true;
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await tick();
  assert.equal(settled, true, 'because a pane whose group emptied by itself is finished, so a stopping daemon exits without a kill');
});

test('ProcessExitsByItself_ChildLeftInItsGroup_ChildKeepsRunning', () => {
  const { open, ptys, timers } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.childEndsOnHangUp = true;
  pty.exit(0, null);
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  assert.equal(pty.groupRunning(), true, 'because a pane the owner did not close is never hung up or killed, whatever its process left behind');
});

test('ProcessExitsByItself_ChildLeftInItsGroup_ToldThenEnded1000', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.childIgnoresHangUp = true;
  pty.exit(5, null);
  assert.deepEqual([link.notices.at(-1), link.ended], [{ type: 'exit', code: 5, signal: null }, PANE_CLOSE.ended], 'because a process that ends by itself ends its pane as it always did');
});

test('StopAll_ChildIgnoringHangUp_NotSettledBeforeTheGrace', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  only(ptys).childIgnoresHangUp = true;
  let settled = false;
  const stopping = panes.stopAll().then(() => { settled = true; });
  await tick();
  const settledBeforeGrace = settled;
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.equal(settledBeforeGrace, false, 'because the daemon stays to kill what a pane\'s process left in its group instead of exiting under it');
});

test('StopAll_ChildIgnoringHangUp_GraceKeepsTheDaemonAlive', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  only(ptys).childIgnoresHangUp = true;
  const stopping = panes.stopAll();
  await tick();
  const holding = timers.keepingAlive();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.deepEqual(holding, [PANE_KILL_GRACE_MILLISECONDS], 'because once the pane\'s own process has exited only the grace timer keeps a stopping daemon alive until the kill');
});

test('StopAll_ChildIgnoringHangUp_SettlesWithTheGroupKilled', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.childIgnoresHangUp = true;
  const stopping = panes.stopAll();
  await tick();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.equal(pty.groupRunning(), false, 'because the daemon exits only after the group its pane left behind has been killed');
});

test('StopAll_ChildIgnoringHangUpAndSlowProcessTable_SettlesWithTheGroupKilled', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.childIgnoresHangUp = true;
  pty.slowProcessTable = true;
  const stopping = panes.stopAll();
  await tick();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.equal(pty.groupRunning(), false, 'because the daemon exits only once the kill reached the group, however long the process table takes to list');
});

test('StopAll_PaneClosedBeforeAndStillInItsGrace_NotSettledBeforeItsKill', async () => {
  const { panes, ptys, timers, open } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  only(ptys).childIgnoresHangUp = true;
  link.go();
  let settled = false;
  const stopping = panes.stopAll().then(() => { settled = true; });
  await tick();
  const settledBeforeGrace = settled;
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  await stopping;
  assert.equal(settledBeforeGrace, false, 'because a pane closed just before the stop still has a group to kill, and the daemon waits for that kill');
});

test('StopAll_NothingLeftInAnyGroup_SettlesWithNoTimerLeft', async () => {
  const { panes, timers, open } = sessions(null);
  open(SHELL_AT_ROOT, PROJECT);
  open({ ...SHELL_AT_ROOT, target: { run: 'shell', folder: '/p/app-wt-2' } }, PROJECT);
  await panes.stopAll();
  assert.deepEqual(timers.pending(), [], 'because a stop with nothing left to kill holds the daemon for nothing');
});

test('PaneLimit_OneMoreThanTheLimit_Refused', () => {
  const { open } = sessions(null);
  for (let opened = 0; opened < MAXIMUM_PANES; opened += 1) open(SHELL_AT_ROOT, PROJECT);
  const extra = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual([extra.notices.map((notice) => notice.type), extra.ended], [['refused'], PANE_CLOSE.refused], 'because the daemon runs at most MAXIMUM_PANES panes across every project');
});

test('PaneLimit_LimitAcrossProjects_Refused', () => {
  const { open } = sessions(null);
  for (let opened = 0; opened < MAXIMUM_PANES; opened += 1) open(SHELL_AT_ROOT, PROJECT);
  const extra = open({ ...SHELL_AT_ROOT, target: { run: 'shell', folder: '/p/site' } }, OTHER_PROJECT);
  assert.equal(extra.ended, PANE_CLOSE.refused, 'because the limit is the machine\'s, not one project\'s');
});

test('PaneLimit_OneClosed_ANewOneOpens', () => {
  const { open, ptys } = sessions(null);
  for (let opened = 0; opened < MAXIMUM_PANES; opened += 1) open(SHELL_AT_ROOT, PROJECT);
  ptys[0]!.exit(0, null);
  const next = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual(next.notices.map((notice) => notice.type), ['started'], 'because a pane that ended frees its place');
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
  const other = open({ ...SHELL_AT_ROOT, target: { run: 'shell', folder: '/p/site' } }, OTHER_PROJECT);
  panes.endProject(PROJECT.id);
  assert.equal(other.ended, null, 'because only the project that went loses its panes');
});

test('PaneLimit_HungUpPaneStillRunning_CountsAgainstTheLimit', () => {
  const { open, ptys } = sessions(null);
  const links = Array.from({ length: MAXIMUM_PANES }, () => open(SHELL_AT_ROOT, PROJECT));
  ptys[0]!.ignoresHangUp = true;
  links[0]!.go();
  const extra = open(SHELL_AT_ROOT, PROJECT);
  assert.equal(extra.ended, PANE_CLOSE.refused, 'because a closed pane whose process still runs is still a process the daemon holds');
});

test('PaneLimit_HungUpPaneKilledAfterTheGrace_ANewOneOpens', () => {
  const { open, ptys, timers } = sessions(null);
  const links = Array.from({ length: MAXIMUM_PANES }, () => open(SHELL_AT_ROOT, PROJECT));
  ptys[0]!.ignoresHangUp = true;
  links[0]!.go();
  timers.fire(PANE_KILL_GRACE_MILLISECONDS);
  const next = open(SHELL_AT_ROOT, PROJECT);
  assert.deepEqual(next.notices.map((notice) => notice.type), ['started'], 'because a pane frees its place once its process has ended');
});

/** A spawner whose ptys throw on write and resize, as node-pty does once the master's fd is destroyed. */
function brokenPtys(): { spawner: PtySpawner; ptys: FakePty[] } {
  const { spawner, ptys } = fakePty(null);
  const broken: PtySpawner = (launch, size, environment) => {
    const spawned = spawner(launch, size, environment);
    if (!spawned.ok) return spawned;
    const destroyed = (): never => { throw new Error('ioctl(2) failed, EBADF'); };
    return { ok: true, pty: { ...spawned.pty, write: destroyed, resize: destroyed } };
  };
  return { spawner: broken, ptys };
}

test('LinkGone_ProcessStillRunning_InputNoLongerReachesThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  link.type(bytes('rm -rf ~\r'));
  assert.deepEqual(pty.received, [], 'because a hung-up pane is on its way out, and its master may already be closed');
});

test('LinkGone_ProcessStillRunning_ResizeNoLongerReachesThePty', () => {
  const { open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  link.go();
  link.control({ type: 'resize', cols: 97, rows: 51 });
  assert.deepEqual(pty.size, { columns: 120, rows: 33 }, 'because resizing a hung-up pane\'s closed master would throw out of the socket listener');
});

test('EndProject_ProcessStillRunning_InputNoLongerReachesThePty', () => {
  const { panes, open, ptys } = sessions(null);
  const link = open(SHELL_AT_ROOT, PROJECT);
  const pty = only(ptys);
  pty.ignoresHangUp = true;
  panes.endProject(PROJECT.id);
  link.type(bytes('ls\r'));
  assert.deepEqual(pty.received, [], 'because a client that ignores the 4404 close must not reach a pane being hung up');
});

test('PtyWriteThrows_TypingDoesNotThrow', () => {
  const { spawner, ptys } = brokenPtys();
  const { open } = sessionsOver(spawner, ptys);
  const link = open(SHELL_AT_ROOT, PROJECT);
  assert.doesNotThrow(() => link.type(bytes('ls\r')), 'because a throw out of the socket listener ends the whole daemon');
});

test('PtyResizeThrows_ResizeDoesNotThrow', () => {
  const { spawner, ptys } = brokenPtys();
  const { open } = sessionsOver(spawner, ptys);
  const link = open(SHELL_AT_ROOT, PROJECT);
  assert.doesNotThrow(() => link.control({ type: 'resize', cols: 97, rows: 51 }), 'because a throw out of the socket listener ends the whole daemon');
});

test('PtyWriteThrows_PaneStaysOpen', () => {
  const { spawner, ptys } = brokenPtys();
  const { open } = sessionsOver(spawner, ptys);
  const link = open(SHELL_AT_ROOT, PROJECT);
  link.type(bytes('ls\r'));
  only(ptys).emit(bytes('still here'));
  assert.equal(new TextDecoder().decode(Buffer.concat(link.output)), 'still here', 'because one failed write leaves the pane and its output running');
});
