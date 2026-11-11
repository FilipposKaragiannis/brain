import assert from 'node:assert/strict';
import os from 'node:os';
import { test } from 'node:test';
import type { PaneLaunch } from '../src/panePlan.ts';
import type { PtyHandle } from '../src/panes.ts';
import { ptySpawner } from '../src/pty.ts';

/** How long a real shell gets to answer before the test gives up. */
const ANSWER_TIMEOUT_MS = 10000;
const ENVIRONMENT = { PATH: '/usr/bin:/bin', TERM: 'xterm-256color', LANG: 'en_US.UTF-8' };

type Ended = { output: string; code: number | null; signal: string | null };

function started(script: string, size = { cols: 80, rows: 24 }): PtyHandle {
  const launch: PaneLaunch = { command: '/bin/sh', args: ['-c', script], cwd: os.tmpdir() };
  const spawned = ptySpawner()(launch, size, ENVIRONMENT);
  if (!spawned.ok) throw new Error(`the real pty did not start: ${spawned.error}`);
  return spawned.pty;
}

/** Everything the process printed, and how it ended. */
function ended(pty: PtyHandle): Promise<Ended> {
  const chunks: Uint8Array[] = [];
  pty.onOutput((bytes) => { chunks.push(bytes); });
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pty.signal('SIGKILL'); reject(new Error('the shell did not end in time')); }, ANSWER_TIMEOUT_MS);
    pty.onExit((code, signal) => {
      clearTimeout(timer);
      // The last output can arrive just after the exit; one turn of the loop lets it land.
      setImmediate(() => { pty.close(); resolve({ output: Buffer.concat(chunks).toString('utf8'), code, signal }); });
    });
  });
}

test('RealPty_ShellOutput_ReachesTheListener', async () => {
  const result = await ended(started('printf "pane-says-%s" hi; exit 3'));
  assert.match(result.output, /pane-says-hi/, 'because the pane draws what the process prints to its terminal');
});

test('RealPty_ShellExitCode_Reported', async () => {
  const result = await ended(started('exit 3'));
  assert.equal(result.code, 3, 'because the page says how the session ended');
});

test('RealPty_AfterAResize_TheProcessSeesTheNewSize', async () => {
  const pty = started('read go; stty size', { cols: 80, rows: 24 });
  const result = ended(pty);
  pty.resize({ cols: 97, rows: 51 });
  pty.write(new TextEncoder().encode('\r'));
  assert.match((await result).output, /51 97/, 'because a TUI lays itself out at the size the page measured');
});
