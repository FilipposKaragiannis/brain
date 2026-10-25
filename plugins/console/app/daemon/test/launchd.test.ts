import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { CommandOutcome, LaunchdDependencies } from '../src/launchd.ts';
import { flagsOfPlist, install, LAUNCHD_LABEL, plistPath, startFailure, status, uninstall } from '../src/launchd.ts';
import { FIXTURE_ROOT } from './fakeRunner.ts';

const OK: CommandOutcome = { code: 0, stdout: '', stderr: '' };
const FAILED: CommandOutcome = { code: 5, stdout: '', stderr: 'Bootstrap failed: 5: Input/output error' };
const RUNNING: CommandOutcome = { code: 0, stdout: `gui/501/${LAUNCHD_LABEL} = {\n\tstate = running\n\tpid = 4242\n}`, stderr: '' };
/** `launchctl print` before the install (not loaded) and after it (running, pid 4242). */
const fresh = (): Record<string, CommandOutcome[]> => ({ print: [FAILED, RUNNING] });

/** launchd, the disk and the port as a test sees them: every call recorded, nothing real touched but a temp state dir. */
function fakeLaunchd(answers: Record<string, CommandOutcome | CommandOutcome[]>, portAnswers = true, holder: string | null = null) {
  const state = mkdtempSync(path.join(os.tmpdir(), 'console-launchd-'));
  const files = new Map<string, string>();
  const calls: string[] = [];
  const lines: string[] = [];
  const privateFolders: string[] = [];
  const answer = (verb: string): CommandOutcome => {
    const given = answers[verb];
    if (Array.isArray(given)) return given.length > 1 ? given.shift()! : given[0] ?? OK;
    return given ?? OK;
  };
  const deps: LaunchdDependencies = {
    launchctl: async (args) => { calls.push(args.join(' ')); return answer(args[0] ?? ''); },
    files: { write: (file, text) => { files.set(file, text); }, remove: (file) => { files.delete(file); }, exists: (file) => files.has(file), read: (file) => files.get(file) ?? '', mkdir: () => {}, privateFolder: (folder) => { privateFolders.push(folder); } },
    portHolder: async () => holder,
    waitForPort: async () => portAnswers, print: (line) => lines.push(line),
    env: { PATH: '/usr/bin:/bin', HOME: '/Users/o', BRAIN_CONSOLE_TOKEN: 'tok', SECRET: 'nope', FLOW_PLUGIN: '/work/brain/plugins/flow' },
    uid: 501, home: '/Users/o', node: '/opt/node/bin/node', daemon: '/work/brain/app/daemon/src/main.ts',
    configPaths: { configFile: path.join(state, 'config.json'), legacyProjectsFile: path.join(state, 'projects.json') },
  };
  return { deps, files, calls, lines, state, privateFolders, cleanup: () => rmSync(state, { recursive: true, force: true }) };
}

const PLIST = plistPath('/Users/o');

test('Install_ValidFlags_WritesTheLaunchAgentWithTheFlagsAndTheEnvironment', async () => {
  const { deps, files, state, cleanup } = fakeLaunchd(fresh());
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
  const { deps, calls, lines, state, cleanup } = fakeLaunchd(fresh());
  try {
    await install(['--project', FIXTURE_ROOT, '--port', '7480', '--state-dir', state], deps);
    assert.deepEqual(calls, [`print gui/501/${LAUNCHD_LABEL}`, `bootstrap gui/501 ${PLIST}`, `print gui/501/${LAUNCHD_LABEL}`], 'because a job not loaded yet is bootstrapped, then launchd is asked whether it really runs');
    assert.match(lines.at(-2) ?? '', /pid 4242/, 'because the pid launchd reports is the proof the job, not something else, serves the port');
    assert.equal(lines.at(-1), 'http://127.0.0.1:7480/?token=tok', 'because the owner opens the console from that URL, printed to the terminal only');
  } finally { cleanup(); }
});

test('Install_AlreadyLoaded_BootedOutFirst', async () => {
  const { deps, calls, state, cleanup } = fakeLaunchd({ print: [OK, RUNNING] });
  try {
    await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps);
    assert.deepEqual(calls.slice(0, 3), [`print gui/501/${LAUNCHD_LABEL}`, `bootout gui/501/${LAUNCHD_LABEL}`, `bootstrap gui/501 ${PLIST}`], 'because a second install must run the new flags, not the old job');
  } finally { cleanup(); }
});

test('Install_BootstrapFails_FallsBackToLoad', async () => {
  const { deps, calls, state, cleanup } = fakeLaunchd({ ...fresh(), bootstrap: FAILED });
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps), 0, 'because load -w worked');
    assert.equal(calls.at(-2), `load -w ${PLIST}`, 'because older launchctl and some sessions refuse bootstrap');
  } finally { cleanup(); }
});

test('Install_PortNeverAnswers_FailsPointingAtTheLog', async () => {
  const { deps, lines, state, cleanup } = fakeLaunchd(fresh(), false);
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

test('Uninstall_Loaded_BootsOutAndRemovesThePlist', async () => {
  const { deps, files, calls, cleanup } = fakeLaunchd({});
  try {
    files.set(PLIST, '<plist/>');
    assert.equal(await uninstall(deps), 0, 'because uninstall succeeds');
    assert.deepEqual([calls, files.has(PLIST)], [[`bootout gui/501/${LAUNCHD_LABEL}`], false], 'because the job stops and does not come back on login');
  } finally { cleanup(); }
});

test('Status_Loaded_SaysThePidAndTheUrl', async () => {
  const { deps, lines, state, cleanup } = fakeLaunchd(fresh());
  try {
    await install(['--project', FIXTURE_ROOT, '--port', '7480', '--state-dir', state], deps);
    lines.length = 0;
    deps.launchctl = async () => RUNNING;
    assert.equal(await status(deps), 0, 'because the job is loaded');
    assert.deepEqual(lines, [`${LAUNCHD_LABEL} is loaded, pid 4242`, 'http://127.0.0.1:7480/?token=tok'], 'because status says whether it runs and where to open it');
  } finally { cleanup(); }
});

test('Status_NotLoaded_SaysSo', async () => {
  const { deps, lines, cleanup } = fakeLaunchd(fresh());
  try {
    assert.equal(await status(deps), 1, 'because nothing runs');
    assert.match(lines[0] ?? '', /is not loaded/, 'because the owner hears it plainly');
  } finally { cleanup(); }
});

test('Install_Plist_KeepsItsFilesPrivate', async () => {
  const { deps, files, state, privateFolders, cleanup } = fakeLaunchd(fresh());
  try {
    await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps);
    assert.ok((files.get(PLIST) ?? '').includes('<key>Umask</key>\n  <integer>63</integer>'), 'because the log launchd writes must not be readable by other accounts');
    assert.deepEqual(privateFolders, [state], 'because the state dir holds the token and the log, closed to 0700');
  } finally { cleanup(); }
});

test('Install_WithToken_RefusedAndNothingWritten', async () => {
  const { deps, files, calls, lines, cleanup } = fakeLaunchd(fresh());
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--token', 'secret'], deps), 2, 'because the plist must never hold the secret');
    assert.deepEqual([files.size, calls], [0, []], 'because a refused install writes and loads nothing');
    assert.match(lines[0] ?? '', /state dir>\/token/, 'because the owner hears where the token comes from instead');
  } finally { cleanup(); }
});

test('Install_PortAlreadyHeld_RefusedNamingTheHolder', async () => {
  const { deps, calls, lines, state, cleanup } = fakeLaunchd(fresh(), true, 'pid 777 (node)');
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps), 1, 'because the job would crash-loop beside the daemon that holds the port');
    assert.match(lines.at(-1) ?? '', /port 7474 is held by pid 777 \(node\)/, 'because the owner must know what to stop');
    assert.equal(calls.some((call) => call.startsWith('bootstrap')), false, 'because nothing is loaded while the port is taken');
  } finally { cleanup(); }
});

test('Install_LoadedButNoPid_FailsPointingAtTheLog', async () => {
  const { deps, lines, state, cleanup } = fakeLaunchd({ print: [FAILED, { code: 0, stdout: 'state = waiting\n', stderr: '' }] });
  try {
    assert.equal(await install(['--project', FIXTURE_ROOT, '--state-dir', state], deps), 1, 'because a job launchd keeps restarting is not running');
    assert.match(lines.at(-1) ?? '', /not running; see .*daemon\.log/, 'because the log says why');
  } finally { cleanup(); }
});

test('StartFailure_UnderLaunchd_SaysItWillBeRestarted', () => {
  assert.match(startFailure('bad config', { BRAIN_CONSOLE_LAUNCHD: '1' }), /cannot start: bad config\n.*starts it again about every 10 s.*daemon:uninstall/, 'because KeepAlive restarts a daemon whose config went bad, and the log must say why it keeps stopping');
  assert.equal(startFailure('bad config', {}), 'brain-console: cannot start: bad config\n', 'because in a terminal the reason alone is enough');
});
