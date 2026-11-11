import assert from 'node:assert/strict';
import { test } from 'node:test';
import { OUTPUT_HIGH_WATER_BYTES, OUTPUT_LOW_WATER_BYTES, PAUSED_EXIT_CHECK_MILLISECONDS } from '../src/paneProtocol.ts';
import { bytes, filler, only, PROJECT, sessions, SHELL_AT_ROOT } from './paneSessionsRig.ts';

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
  timers.fire(PAUSED_EXIT_CHECK_MILLISECONDS);
  assert.equal(new TextDecoder().decode(link.output.at(-1)), LAST_WORDS, 'because a crashing agent\'s last line is what the owner most needs to read, paused or not');
});

test('ProcessEndsWhilePaused_ExitTold', () => {
  const { link, pty, timers } = pausedPane();
  pty.finish([bytes(LAST_WORDS)], 1);
  timers.fire(PAUSED_EXIT_CHECK_MILLISECONDS);
  assert.deepEqual(link.notices.at(-1), { type: 'exit', code: 1, signal: null }, 'because the page says how the session ended even when it ended while paused');
});

test('ProcessStillRunningWhilePaused_PtyStaysPaused', () => {
  const { pty, timers } = pausedPane();
  timers.fire(PAUSED_EXIT_CHECK_MILLISECONDS);
  assert.equal(pty.paused, true, 'because a live process stays paused until the page catches up');
});

test('ProcessEndsWhilePaused_TailPastTheHighWater_ExitStillTold', () => {
  const { link, pty, timers } = pausedPane();
  pty.finish([filler(OUTPUT_HIGH_WATER_BYTES + 1), filler(OUTPUT_HIGH_WATER_BYTES + 1)], 2);
  timers.fire(PAUSED_EXIT_CHECK_MILLISECONDS);
  assert.deepEqual(link.notices.at(-1), { type: 'exit', code: 2, signal: null }, 'because once the process is gone, pausing again only stalls the tail it left');
});

test('PausedPaneEnds_NoExitCheckLeftBehind', () => {
  const { pty, timers } = pausedPane();
  pty.exit(0, null);
  timers.fire(PAUSED_EXIT_CHECK_MILLISECONDS);
  assert.equal(pty.exitProbes, 0, 'because a pane that ended must not keep polling a pid the system may reuse');
});

test('PausedPaneResumed_NoExitCheckLeftBehind', () => {
  const { link, pty, timers } = pausedPane();
  link.control({ type: 'ack', bytes: OUTPUT_HIGH_WATER_BYTES + 1 });
  timers.fire(PAUSED_EXIT_CHECK_MILLISECONDS);
  assert.equal(pty.exitProbes, 0, 'because a pty that reads on needs no check for an exit it will read itself');
});
