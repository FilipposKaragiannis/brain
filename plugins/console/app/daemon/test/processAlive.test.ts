import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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

test('ProcessAlive_ProcessOfAnotherUser_True', () => {
  const LAUNCHD_PID = 1;
  assert.equal(processAlive(LAUNCHD_PID), true, 'because a process the daemon may not signal still exists');
});
