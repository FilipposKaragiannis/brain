import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { readConfig } from '../src/config.ts';
import { FIXTURE_ROOT, FIXTURES } from './fakeRunner.ts';

test('ProjectFlag_ReadWithDefaults', () => {
  const stateDir = mkdtempSync(path.join(os.tmpdir(), 'console-config-'));
  try {
    const result = readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {});
    assert.ok(result.ok, 'because the fixture holds a .flow/config.yaml');
    if (!result.ok) return;
    assert.equal(result.config.projects[0]?.id, 'project', 'because the id is the folder name');
    assert.equal(result.config.host, '127.0.0.1', 'because the daemon only ever binds localhost');
    assert.equal(result.config.stateDir, stateDir, 'because the state dir flag is honoured');
  } finally { rmSync(stateDir, { recursive: true, force: true }); }
});

test('NoToken_OneIsMadeAndKept', () => {
  const stateDir = mkdtempSync(path.join(os.tmpdir(), 'console-config-'));
  try {
    const first = readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {});
    const second = readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {});
    assert.ok(first.ok && second.ok, 'because both reads are valid');
    if (!first.ok || !second.ok) return;
    assert.ok(first.config.token.length >= 32, 'because a route is never open without a secret, even on localhost');
    assert.equal(second.config.token, first.config.token, 'because the token is kept in the state dir so the URL survives a restart');
    assert.equal(readFileSync(path.join(stateDir, 'token'), 'utf8').trim(), first.config.token, 'because the token file is where the owner finds it');
  } finally { rmSync(stateDir, { recursive: true, force: true }); }
});

test('RootWithoutFlowHome_Refused', () => {
  const result = readConfig(['--project', `${FIXTURES}/project-wt-2`], {});
  assert.equal(result.ok, false, 'because a project must be initialised by flow:init first');
});

test('EnvironmentList_UsedWhenNoFlags', () => {
  const result = readConfig([], { BRAIN_CONSOLE_PROJECTS: FIXTURE_ROOT, BRAIN_CONSOLE_TOKEN: 'secret', BRAIN_CONSOLE_STATE: os.tmpdir() });
  assert.ok(result.ok && result.config.token === 'secret', 'because the environment is the second source of projects and the token');
});

test('UnknownFlag_Refused', () => {
  assert.equal(readConfig(['--nope'], {}).ok, false, 'because a typo must not start a daemon with defaults');
});
