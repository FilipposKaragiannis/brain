import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { parsePidRecord, pidFilePath, removePidFile, writePidFile } from '../src/pidFile.ts';

test('PidFile_WrittenThenRead_GivesTheRecordBack', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-pid-'));
  try {
    writePidFile(dir, { pid: 77, port: 7480, config: '/c.json', argv: ['--port', '7480'] });
    assert.deepEqual(parsePidRecord(readFileSync(pidFilePath(dir), 'utf8')), { pid: 77, port: 7480, config: '/c.json', argv: ['--port', '7480'] }, 'because stop, status and restart read back what the daemon wrote');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('PidFile_RemovedByAnotherPid_Kept', () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-pid-'));
  try {
    writePidFile(dir, { pid: 77, port: 7480, config: '/c.json', argv: [] });
    removePidFile(dir, 78);
    assert.equal(existsSync(pidFilePath(dir)), true, 'because a daemon that stops must not remove the file of a newer one');
    removePidFile(dir, 77);
    assert.equal(existsSync(pidFilePath(dir)), false, 'because the daemon that wrote it removes it when it stops');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('PidFile_NotARecord_ReadsAsNone', () => {
  assert.equal(parsePidRecord('4242\n'), null, 'because a half-written or hand-written file names no daemon');
});
