import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { test } from 'node:test';
import { processAlive } from '../src/processAlive.ts';

test('ProcessAlive_RunningProcess_True', () => {
  assert.equal(processAlive(process.pid), true, 'because the test runner itself is running');
});

test('ProcessAlive_ProcessThatEndedAndWasReaped_False', async () => {
  const child = spawn('/bin/sh', ['-c', 'exit 0'], { stdio: 'ignore' });
  const pid = child.pid!;
  await once(child, 'exit');
  assert.equal(processAlive(pid), false, 'because a pane resumes for its tail only once its process is gone');
});

const INIT_PID = 1;

/** Why pid 1 cannot stand for a process the runner may not signal, or false when it can. */
function initNotForeign(): string | false {
  if (process.getuid?.() === 0) return 'the runner is root, so it may signal every process';
  const initOwner = Number(execFileSync('ps', ['-o', 'uid=', '-p', String(INIT_PID)], { encoding: 'utf8' }).trim());
  if (initOwner === process.getuid?.()) return 'pid 1 belongs to the runner, as in a container';
  return false;
}

test('ProcessAlive_ProcessOfAnotherUser_True', { skip: initNotForeign() }, () => {
  assert.equal(processAlive(INIT_PID), true, 'because a process the daemon may not signal still exists');
});
