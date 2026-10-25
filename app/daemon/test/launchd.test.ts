import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { CommandOutcome, LaunchdDependencies } from '../src/launchd.ts';
import { flagsOfPlist, install, LAUNCHD_LABEL, plistPath, status, uninstall } from '../src/launchd.ts';
import { FIXTURE_ROOT } from './fakeRunner.ts';

const OK: CommandOutcome = { code: 0, stdout: '', stderr: '' };
const FAILED: CommandOutcome = { code: 5, stdout: '', stderr: 'Bootstrap failed: 5: Input/output error' };

/** launchd, the disk and the port as a test sees them: every call recorded, nothing real touched but a temp state dir. */
function fakeLaunchd(answers: Record<string, CommandOutcome>, portAnswers = true) {
  const state = mkdtempSync(path.join(os.tmpdir(), 'console-launchd-'));
  const files = new Map<string, string>();
  const calls: string[] = [];
  const lines: string[] = [];
  const deps: LaunchdDependencies = {
    launchctl: async (args) => { calls.push(args.join(' ')); return answers[args[0] ?? ''] ?? OK; },
    files: { write: (file, text) => { files.set(file, text); }, remove: (file) => { files.delete(file); }, exists: (file) => files.has(file), read: (file) => files.get(file) ?? '', mkdir: () => {} },
    waitForPort: async () => portAnswers, print: (line) => lines.push(line),
    env: { PATH: '/usr/bin:/bin', HOME: '/Users/o', BRAIN_CONSOLE_TOKEN: 'tok', SECRET: 'nope', FLOW_PLUGIN: '/work/brain/plugins/flow' },
    uid: 501, home: '/Users/o', node: '/opt/node/bin/node', daemon: '/work/brain/app/daemon/src/main.ts',
    configPaths: { configFile: path.join(state, 'config.json'), legacyProjectsFile: path.join(state, 'projects.json') },
  };
  return { deps, files, calls, lines, state, cleanup: () => rmSync(state, { recursive: true, force: true }) };
}

const PLIST = plistPath('/Users/o');

test('Install_WritesTheLaunchAgentWithTheFlagsAndTheEnvironment', async () => {
  const { deps, files, state, cleanup } = fakeLaunchd({ print: FAILED });
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--port', '7480', '--state-dir', state], deps), 0, 'because the flags are valid and the port answers');
    const plist = files.get(PLIST) ?? '';
    assert.equal(PLIST, '/Users/o/Library/LaunchAgents/com.brain.console.plist', 'because the agent lives where launchd looks at login');
    for (const part of ['<key>RunAtLoad</key>\n  <true/>', '<key>KeepAlive</key>\n  <true/>', '<string>/opt/node/bin/node</string>', '<string>/work/brain/app/daemon/src/main.ts</string>', `<string>${FIXTURE_ROOT}</string>`, '<string>7480</string>', '<key>PATH</key>\n    <string>/usr/bin:/bin</string>', '<key>HOME</key>', '<key>BRAIN_CONSOLE_LAUNCHD</key>\n    <string>1</string>', '<key>FLOW_PLUGIN</key>', `<string>${state}/daemon.log</string>`]) {
      assert.ok(plist.includes(part), `because the plist must carry ${part.split('\n')[0]}`);
    }
    assert.equal(plist.includes('SECRET'), false, 'because only the variables the daemon needs go into the plist');
    assert.deepEqual(flagsOfPlist(plist), ['--project', FIXTURE_ROOT, '--port', '7480', '--state-dir', state], 'because status reads the same flags back');
  } finally { cleanup(); }
});

test('Install_NotLoaded_BootstrapsThenPrintsTheUrl', async () => {
  const { deps, calls, lines, state, cleanup } = fakeLaunchd({ print: FAILED });
  try {
    await install(['--project', FIXTURE_ROOT, '--port', '7480', '--state-dir', state], deps);
    assert.deepEqual(calls, [`print gui/501/${LAUNCHD_LABEL}`, `bootstrap gui/501 ${PLIST}`], 'because a job not loaded yet is bootstrapped into the login session');
    assert.equal(lines.at(-1), 'http://127.0.0.1:7480/?token=tok', 'because the owner opens the console from that URL');
  } finally { cleanup(); }
});

test('Install_AlreadyLoaded_BootedOutFirst', async () => {
  const { deps, calls, state, cleanup } = fakeLaunchd({});
  try {
    await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps);
    assert.deepEqual(calls.slice(0, 3), [`print gui/501/${LAUNCHD_LABEL}`, `bootout gui/501/${LAUNCHD_LABEL}`, `bootstrap gui/501 ${PLIST}`], 'because a second install must run the new flags, not the old job');
  } finally { cleanup(); }
});

test('Install_BootstrapFails_FallsBackToLoad', async () => {
  const { deps, calls, state, cleanup } = fakeLaunchd({ print: FAILED, bootstrap: FAILED });
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps), 0, 'because load -w worked');
    assert.equal(calls.at(-1), `load -w ${PLIST}`, 'because older launchctl and some sessions refuse bootstrap');
  } finally { cleanup(); }
});

test('Install_PortNeverAnswers_FailsPointingAtTheLog', async () => {
  const { deps, lines, state, cleanup } = fakeLaunchd({ print: FAILED }, false);
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps), 1, 'because a daemon that never listens is not installed');
    assert.match(lines.at(-1) ?? '', /daemon\.log/, 'because the log says why it did not start');
  } finally { cleanup(); }
});

test('Install_BadFlags_NothingWrittenOrLoaded', async () => {
  const { deps, files, calls, cleanup } = fakeLaunchd({});
  try {
    assert.equal(await install(['--project', '/nowhere'], deps), 2, 'because a root without a flow would make launchd restart a failing daemon for ever');
    assert.deepEqual([files.size, calls], [0, []], 'because a refused install leaves launchd alone');
  } finally { cleanup(); }
});

test('Uninstall_BootsOutAndRemovesThePlist', async () => {
  const { deps, files, calls, cleanup } = fakeLaunchd({});
  try {
    files.set(PLIST, '<plist/>');
    assert.equal(await uninstall(deps), 0, 'because uninstall succeeds');
    assert.deepEqual([calls, files.has(PLIST)], [[`bootout gui/501/${LAUNCHD_LABEL}`], false], 'because the job stops and does not come back on login');
  } finally { cleanup(); }
});

test('Status_Loaded_SaysThePidAndTheUrl', async () => {
  const { deps, lines, state, cleanup } = fakeLaunchd({ print: FAILED });
  try {
    await install(['--project', FIXTURE_ROOT, '--port', '7480', '--state-dir', state], deps);
    lines.length = 0;
    deps.launchctl = async () => ({ code: 0, stdout: `gui/501/${LAUNCHD_LABEL} = {\n\tstate = running\n\tpid = 4242\n}`, stderr: '' });
    assert.equal(await status(deps), 0, 'because the job is loaded');
    assert.deepEqual(lines, [`${LAUNCHD_LABEL} is loaded, pid 4242`, 'http://127.0.0.1:7480/?token=tok'], 'because status says whether it runs and where to open it');
  } finally { cleanup(); }
});

test('Status_NotLoaded_SaysSo', async () => {
  const { deps, lines, cleanup } = fakeLaunchd({ print: FAILED });
  try {
    assert.equal(await status(deps), 1, 'because nothing runs');
    assert.match(lines[0] ?? '', /is not loaded/, 'because the owner hears it plainly');
  } finally { cleanup(); }
});
