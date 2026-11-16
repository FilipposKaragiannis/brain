import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { PaneLaunch } from '../src/panePlan.ts';
import { PANE_KILL_GRACE_MILLISECONDS } from '../src/paneProtocol.ts';
import type { PaneSize } from '../src/paneProtocol.ts';
import { PaneSessions } from '../src/panes.ts';
import type { PaneLink, PtyHandle, PtySpawner } from '../src/panes.ts';
import { silentLogger } from '../src/log.ts';
import { fakeScheduler } from './fakeSpawner.ts';
import { processAlive } from '../src/processAlive.ts';
import { ptySpawner } from '../src/pty.ts';

/** How long a real shell gets to answer before the test gives up. */
const ANSWER_TIMEOUT_MILLISECONDS = 10000;
const ENVIRONMENT = { PATH: '/usr/bin:/bin', TERM: 'xterm-256color', LANG: 'en_US.UTF-8' };

type Ended = { output: string; code: number | null; signal: string | null };

const TERMINAL_SIZE: PaneSize = { columns: 80, rows: 24 };

function started(script: string, size: PaneSize): PtyHandle {
  const launch: PaneLaunch = { command: '/bin/sh', commandArguments: ['-c', script], workingFolder: os.tmpdir() };
  const spawned = ptySpawner()(launch, size, ENVIRONMENT);
  if (!spawned.ok) throw new Error(`the real pty did not start: ${spawned.error}`);
  return spawned.pty;
}

/** Everything the process printed, and how it ended. */
function ended(pty: PtyHandle): Promise<Ended> {
  const chunks: Uint8Array[] = [];
  pty.onOutput((bytes) => { chunks.push(bytes); });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pty.signal('SIGKILL'); reject(new Error('the shell did not end in time')); }, ANSWER_TIMEOUT_MILLISECONDS);
    pty.onExit((code, signal) => {
      clearTimeout(timer);
      void settleAfterExit().then(() => { pty.close(); resolve({ output: Buffer.concat(chunks).toString('utf8'), code, signal }); });
    });
  });
}

function settleAfterExit(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

test('RealPty_ShellOutput_ReachesTheListener', async () => {
  const result = await ended(started('printf "pane-says-%s" hi; exit 3', TERMINAL_SIZE));
  assert.match(result.output, /pane-says-hi/, 'because the pane draws what the process prints to its terminal');
});

test('RealPty_ShellExitCode_Reported', async () => {
  const result = await ended(started('exit 3', TERMINAL_SIZE));
  assert.equal(result.code, 3, 'because the page says how the session ended');
});

test('RealPty_AfterAResize_TheProcessSeesTheNewSize', async () => {
  const pty = started('read go; stty size', TERMINAL_SIZE);
  const result = ended(pty);
  pty.resize({ columns: 97, rows: 51 });
  pty.write(new TextEncoder().encode('\r'));
  assert.match((await result).output, /51 97/, 'because a TUI lays itself out at the size the page measured');
});

test('RealPty_InputIsAViewIntoALargerFrame_OnlyTheViewReachesTheProcess', async () => {
  const pty = started('read line; printf "line=[%s]" "$line"', TERMINAL_SIZE);
  const result = ended(pty);
  const frame = new TextEncoder().encode('XXXXhelloYYYY');
  pty.write(frame.subarray(4, 9));
  pty.write(new TextEncoder().encode('\r'));
  assert.match((await result).output, /line=\[hello\]/, 'because a frame the socket hands over as a slice of a larger buffer carries only its own bytes');
});

/** The pid of a child the shell started in the background, read from the first line it prints. */
async function childPid(pty: PtyHandle): Promise<number> {
  const chunks: Uint8Array[] = [];
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('the shell did not print its child\'s pid in time')), ANSWER_TIMEOUT_MILLISECONDS);
    pty.onOutput((bytes) => {
      chunks.push(bytes);
      const printed = /child=(\d+)/.exec(Buffer.concat(chunks).toString('utf8'));
      if (printed !== null) { clearTimeout(timer); resolve(Number(printed[1])); }
    });
  });
}

/** Waits until a pid no longer names a process, or the answer timeout passes. */
async function gone(pid: number): Promise<boolean> {
  const deadline = Date.now() + ANSWER_TIMEOUT_MILLISECONDS;
  while (processAlive(pid)) {
    if (Date.now() > deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return true;
}

/**
 * A shell that runs until it is hung up. It does not sit in `wait` on a background child: bash
 * there may take the child's hang-up first, report it and exit 0, so the shell's own end would
 * not say it was hung up.
 */
const SHELL_IN_A_LOOP = 'echo child=$$; while :; do sleep 1; done';

test('RealPty_HangUp_EndsTheShell', async () => {
  const pty = started(SHELL_IN_A_LOOP, TERMINAL_SIZE);
  await childPid(pty);
  const result = ended(pty);
  pty.signal('SIGHUP');
  assert.equal((await result).signal, 'SIGHUP', 'because closing a pane hangs up the process it runs');
});

/**
 * A shell that survives a hang-up, as an agent's wrapper may, around a child that does not. The
 * child prints its own pid once it runs its own program: until that exec it is a fork of the
 * shell that still carries the shell's HUP trap, and a hang-up in that window misses it.
 */
const HANG_UP_SURVIVOR_WITH_A_CHILD = 'trap ":" HUP; sh -c \'echo child=$$; exec sleep 600\' & while :; do sleep 1; done';

test('RealPty_HangUp_ReachesTheChildOfAShellThatSurvivesIt', async () => {
  const pty = started(HANG_UP_SURVIVOR_WITH_A_CHILD, TERMINAL_SIZE);
  const child = await childPid(pty);
  const result = ended(pty);
  try {
    pty.signal('SIGHUP');
    assert.equal(await gone(child), true, 'because the hang-up reaches the whole process group, so nothing the session started outlives the pane');
  } finally {
    pty.signal('SIGKILL');
    await result;
    if (processAlive(child)) process.kill(child, 'SIGKILL');
  }
});

test('RealPty_Kill_EndsAShellThatIgnoresTheHangUp', async () => {
  const pty = started('trap "" HUP; echo child=$$; while :; do sleep 1; done', TERMINAL_SIZE);
  await childPid(pty);
  const result = ended(pty);
  pty.signal('SIGHUP');
  pty.signal('SIGKILL');
  assert.equal((await result).signal, 'SIGKILL', 'because SIGKILL ends a shell that traps the hang-up');
});

test('RealPty_CommandMissing_EndsWithAFailure', async () => {
  const launch: PaneLaunch = { command: '/no/such/folder/brain-agent', commandArguments: [], workingFolder: os.tmpdir() };
  const spawned = ptySpawner()(launch, TERMINAL_SIZE, ENVIRONMENT);
  const failed = spawned.ok ? isFailureCode((await ended(spawned.pty)).code) : spawned.error.includes(launch.command);
  assert.equal(failed, true, 'because a program that never ran ends with a failing code or a refusal naming it, never like a session that ended well');
});

function isFailureCode(code: number | null): boolean {
  return code !== null && code !== 0;
}

/**
 * The session pane's shape: a shell that dies on the hang-up, as `/bin/sh -c '<resume>; exec
 * <shell> -l'` does, around a child in its group that ignores it, as a resumed agent may. The
 * child prints its own pid once it ignores the hang-up and runs its own program.
 */
const SHELL_DYING_WITH_A_CHILD_IGNORING_THE_HANG_UP = `#!/bin/sh
sh -c 'trap "" HUP; echo child=$$; exec sleep 600' &
while :; do sleep 1; done
`;

/** A link the test drops, as a page does when the owner closes the pane. */
function droppableLink(): { link: PaneLink; drop(): void } {
  let gone: () => void = () => {};
  return {
    link: { output: () => {}, tell: () => {}, end: () => {}, onInput: () => {}, onControl: () => {}, onGone: (listener) => { gone = listener; }, queuedBytes: () => 0 },
    drop: () => gone(),
  };
}

/**
 * The same shape under job control, as in an interactive shell: the child runs in a job group of
 * its own, outside the group the shell leads.
 */
const SHELL_DYING_WITH_A_JOB_IGNORING_THE_HANG_UP = `#!/bin/sh
set -m
sh -c 'trap "" HUP; echo child=$$; exec sleep 600' &
while :; do sleep 1; done
`;

/** Opens a pane on the script, drops its page, lets the grace run out and says whether the child is gone. */
async function childGoneOncePaneClosed(script: string): Promise<boolean> {
  const folder = mkdtempSync(path.join(os.tmpdir(), 'pane-group-'));
  const shell = path.join(folder, 'session.sh');
  writeFileSync(shell, script);
  chmodSync(shell, 0o755);
  const started: PtyHandle[] = [];
  const shellEnded: Promise<void>[] = [];
  const realSpawner = ptySpawner();
  const spawner: PtySpawner = (launch, size, environment) => {
    const spawned = realSpawner(launch, size, environment);
    if (spawned.ok) { started.push(spawned.pty); shellEnded.push(new Promise((resolve) => spawned.pty.onExit(() => resolve()))); }
    return spawned;
  };
  const timers = fakeScheduler();
  const panes = new PaneSessions({ spawner, host: { shell, environment: ENVIRONMENT, isFolder: () => true }, scheduler: timers.scheduler, log: silentLogger });
  const page = droppableLink();
  panes.open('app', { target: { run: 'shell', folder }, size: TERMINAL_SIZE }, { root: folder, folders: [folder], sessions: [], gateSessions: [] }, page.link);
  const pane = started[0]!;
  const child = await childPid(pane);
  try {
    page.drop();
    await shellEnded[0];
    await settleAfterExit();
    timers.fire(PANE_KILL_GRACE_MILLISECONDS);
    return await gone(child);
  } finally {
    if (processAlive(child)) process.kill(child, 'SIGKILL');
    rmSync(folder, { recursive: true, force: true });
  }
}

test('RealPaneClosed_ShellDiesOnTheHangUpAndItsChildIgnoresIt_ChildKilledOnceTheGraceRunsOut', async () => {
  assert.equal(await childGoneOncePaneClosed(SHELL_DYING_WITH_A_CHILD_IGNORING_THE_HANG_UP), true, 'because a closed pane leaves nothing running, even a process that ignored the hang-up its shell died of');
});

test('RealPaneClosed_ChildInAJobGroupIgnoresTheHangUp_ChildKilledOnceTheGraceRunsOut', async () => {
  assert.equal(await childGoneOncePaneClosed(SHELL_DYING_WITH_A_JOB_IGNORING_THE_HANG_UP), true, 'because a closed pane ends the job groups its shell started too, not only the group the shell leads');
});

test('RealPty_KillAfterTheShellEnded_ReachesAJobInAGroupOfItsOwn', async () => {
  const pty = started(SHELL_DYING_WITH_A_JOB_IGNORING_THE_HANG_UP, TERMINAL_SIZE);
  const child = await childPid(pty);
  const result = ended(pty);
  try {
    pty.signal('SIGHUP');
    await result;
    pty.signal('SIGKILL');
    assert.equal(await gone(child), true, 'because a job the shell started stays the pane\'s after the shell ended, so the kill still reaches it');
  } finally {
    if (processAlive(child)) process.kill(child, 'SIGKILL');
  }
});
