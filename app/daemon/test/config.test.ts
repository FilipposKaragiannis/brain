import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { readConfig, startReport } from '../src/config.ts';
import type { ConfigPaths } from '../src/settings.ts';
import { FIXTURE_ROOT, FIXTURES } from './fakeRunner.ts';

/** An empty config folder, so no test reads the owner's own settings. */
const NO_FILES = configDir({}).paths;

test('ProjectFlag_ReadWithDefaults', () => {
  const stateDir = mkdtempSync(path.join(os.tmpdir(), 'console-config-'));
  try {
    const result = readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {}, NO_FILES);
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
    const first = readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {}, NO_FILES);
    const second = readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {}, NO_FILES);
    assert.ok(first.ok && second.ok, 'because both reads are valid');
    if (!first.ok || !second.ok) return;
    assert.ok(first.config.token.length >= 32, 'because a route is never open without a secret, even on localhost');
    assert.equal(second.config.token, first.config.token, 'because the token is kept in the state dir so the URL survives a restart');
    assert.equal(readFileSync(path.join(stateDir, 'token'), 'utf8').trim(), first.config.token, 'because the token file is where the owner finds it');
  } finally { rmSync(stateDir, { recursive: true, force: true }); }
});

test('RootWithoutFlowHome_Refused', () => {
  const result = readConfig(['--project', `${FIXTURES}/project-wt-2`], {}, NO_FILES);
  assert.equal(result.ok, false, 'because a project must be initialised by flow:init first');
});

test('EnvironmentList_UsedWhenNoFlags', () => {
  const result = readConfig([], { BRAIN_CONSOLE_PROJECTS: FIXTURE_ROOT, BRAIN_CONSOLE_TOKEN: 'secret', BRAIN_CONSOLE_STATE: os.tmpdir() }, NO_FILES);
  assert.ok(result.ok && result.config.token === 'secret', 'because the environment is the second source of projects and the token');
});

test('UnknownFlag_Refused', () => {
  assert.equal(readConfig(['--nope'], {}, NO_FILES).ok, false, 'because a typo must not start a daemon with defaults');
});

function configDir(files: Record<string, unknown>): { paths: ConfigPaths; dir: string } {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-settings-'));
  for (const [name, content] of Object.entries(files)) writeFileSync(path.join(dir, name), typeof content === 'string' ? content : JSON.stringify(content));
  return { dir, paths: { configFile: path.join(dir, 'config.json'), legacyProjectsFile: path.join(dir, 'projects.json') } };
}

const LOCAL_ROOT = path.join(FIXTURES, 'project-local');
const QUIET_ENV = { BRAIN_CONSOLE_TOKEN: 't', BRAIN_CONSOLE_STATE: os.tmpdir() };

test('ConfigFile_AllThreeSet_ProjectsPortAndTerminalRead', () => {
  const { dir, paths } = configDir({ 'config.json': { projects: [{ root: LOCAL_ROOT }], terminal: 'ghostty', port: 7480 } });
  try {
    const result = readConfig([], QUIET_ENV, paths);
    assert.ok(result.ok, 'because the file names a root that holds a flow');
    if (!result.ok) return;
    assert.deepEqual([result.config.projects.map((project) => project.id), result.config.port, result.config.stored.file.terminal], [['project-local'], 7480, 'ghostty'], 'because config.json carries the projects, the port and the terminal');
    assert.deepEqual(result.config.origins, { projects: 'file', port: 'file' }, 'because both came from the file');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ConfigFile_Absent_ProjectsJsonStillRead', () => {
  const { dir, paths } = configDir({ 'projects.json': { projects: [{ root: LOCAL_ROOT }] } });
  try {
    const result = readConfig([], QUIET_ENV, paths);
    assert.ok(result.ok && result.config.projects[0]?.root === LOCAL_ROOT, 'because an owner with only the older projects.json must not lose the projects');
    assert.ok(result.ok && result.config.stored.legacy, 'because Settings says the projects came from the old file');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ConfigFile_ProjectsJsonToo_ConfigFileWins', () => {
  const { dir, paths } = configDir({ 'config.json': { projects: [{ root: LOCAL_ROOT }] }, 'projects.json': { projects: [{ root: FIXTURE_ROOT }] } });
  try {
    const result = readConfig([], QUIET_ENV, paths);
    assert.ok(result.ok && result.config.projects.map((project) => project.root).join() === LOCAL_ROOT, 'because projects.json is only the fallback for an absent config.json');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('Flags_FileSaysOtherwise_FlagWinsAndSaysSo', () => {
  const { dir, paths } = configDir({ 'config.json': { projects: [{ root: LOCAL_ROOT }], port: 7480 } });
  try {
    const result = readConfig(['--project', FIXTURE_ROOT, '--port', '7475'], QUIET_ENV, paths);
    assert.ok(result.ok, 'because the flags are valid');
    if (!result.ok) return;
    assert.deepEqual([result.config.projects[0]?.root, result.config.port, result.config.origins], [FIXTURE_ROOT, 7475, { projects: 'flag', port: 'flag' }], 'because a flag beats the file, and Settings must say where each came from');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('Environment_FileSaysOtherwise_EnvironmentWins', () => {
  const { dir, paths } = configDir({ 'config.json': { projects: [{ root: LOCAL_ROOT }] } });
  try {
    const result = readConfig([], { ...QUIET_ENV, BRAIN_CONSOLE_PROJECTS: FIXTURE_ROOT }, paths);
    assert.ok(result.ok && result.config.origins.projects === 'environment' && result.config.port === 7474 && result.config.origins.port === 'default', 'because the environment comes before the file and the port falls back to the default');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ConfigFile_NotJson_Refused', () => {
  const { dir, paths } = configDir({ 'config.json': '{nope' });
  try {
    const result = readConfig(['--project', FIXTURE_ROOT], QUIET_ENV, paths);
    assert.equal(result.ok, false, 'because a broken settings file must be fixed, not quietly ignored');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('ConfigFile_UnknownTerminal_Refused', () => {
  const { dir, paths } = configDir({ 'config.json': { terminal: 'kitty' } });
  try {
    assert.equal(readConfig(['--project', FIXTURE_ROOT], QUIET_ENV, paths).ok, false, 'because only the named terminals or a command array open a folder');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('LaunchdVariable_Set_NotedInTheConfig', () => {
  const result = readConfig(['--project', FIXTURE_ROOT], { ...QUIET_ENV, BRAIN_CONSOLE_LAUNCHD: '1' }, NO_FILES);
  assert.ok(result.ok && result.config.launchd, 'because the plist install writes sets it, and Settings says the daemon runs under launchd');
});

test('StartReport_LogLine_NeverHoldsTheToken', () => {
  const read = readConfig(['--project', FIXTURE_ROOT], { BRAIN_CONSOLE_TOKEN: 'sekrit-token', BRAIN_CONSOLE_STATE: os.tmpdir() }, NO_FILES);
  assert.ok(read.ok, 'because the config is valid');
  if (!read.ok) return;
  const quiet = startReport(read.config, 'none', false);
  assert.equal(JSON.stringify(quiet.fields).includes('sekrit-token'), false, 'because under launchd the log is a file, and the token must not land in it');
  assert.equal(quiet.terminal, null, 'because without a terminal there is no one to print the URL to');
  assert.match(startReport(read.config, 'none', true).terminal ?? '', /\?token=sekrit-token/, 'because the owner at a terminal still gets the URL to open');
});

test('StateDir_MadeOnFirstStart_ClosedToTheOwner', () => {
  const parent = mkdtempSync(path.join(os.tmpdir(), 'console-private-'));
  try {
    const stateDir = path.join(parent, 'state');
    mkdirSync(stateDir, { mode: 0o755 });
    readConfig(['--project', FIXTURE_ROOT, '--state-dir', stateDir], {}, NO_FILES);
    assert.equal(statSync(stateDir).mode & 0o777, 0o700, 'because the folder holds the token, the audit log and the daemon log');
  } finally { rmSync(parent, { recursive: true, force: true }); }
});
