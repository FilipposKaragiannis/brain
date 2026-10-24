import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readConfig } from '../src/config.ts';
import { FIXTURE_ROOT, FIXTURES } from './fakeRunner.ts';

test('ProjectFlag_ReadWithDefaults', () => {
  const result = readConfig(['--project', FIXTURE_ROOT], {});
  assert.ok(result.ok, 'because the fixture holds a .flow/config.yaml');
  if (!result.ok) return;
  assert.equal(result.config.projects[0]?.id, 'project', 'because the id is the folder name');
  assert.equal(result.config.host, '127.0.0.1', 'because the daemon only ever binds localhost');
  assert.equal(result.config.token, null, 'because no token means open on localhost');
});

test('RootWithoutFlowHome_Refused', () => {
  const result = readConfig(['--project', `${FIXTURES}/project-wt-2`], {});
  assert.equal(result.ok, false, 'because a project must be initialised by flow:init first');
});

test('EnvironmentList_UsedWhenNoFlags', () => {
  const result = readConfig([], { BRAIN_CONSOLE_PROJECTS: FIXTURE_ROOT, BRAIN_CONSOLE_TOKEN: 'secret' });
  assert.ok(result.ok && result.config.token === 'secret', 'because the environment is the second source of projects and the token');
});

test('UnknownFlag_Refused', () => {
  assert.equal(readConfig(['--nope'], {}).ok, false, 'because a typo must not start a daemon with defaults');
});
