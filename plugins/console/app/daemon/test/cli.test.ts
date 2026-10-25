import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { CliDependencies, HttpAnswer } from '../src/cli.ts';
import { compareVersions, daemonEntry, HELP, newestCachedPlugin, runCli } from '../src/cli.ts';
import type { CommandOutcome } from '../src/launchd.ts';
import { LAUNCHD_LABEL, plistPath, plistXml } from '../src/launchd.ts';
import { pidFilePath } from '../src/pidFile.ts';
import { FIXTURE_ROOT, FIXTURES } from './fakeRunner.ts';

const LOCAL_ROOT = path.join(FIXTURES, 'project-local');
const OK: CommandOutcome = { code: 0, stdout: '', stderr: '' };
const NOT_LOADED: CommandOutcome = { code: 113, stdout: '', stderr: 'Could not find service' };
const RUNNING: CommandOutcome = { code: 0, stdout: `gui/501/${LAUNCHD_LABEL} = {\n\tstate = running\n\tpid = 4242\n}`, stderr: '' };

type Fake = {
  deps: CliDependencies; dir: string; home: string; state: string; config: string; lines: string[]; calls: string[]; alive: Set<number>; killed: number[];
  requests: { method: string; url: string; body: unknown }[]; opened: string[]; tailed: [string, boolean][]; scripts: [string, string[]][]; started: string[][];
  cleanup: () => void;
};

/**
 * A home, a state dir and a config file in a temp folder, launchd answering as `loaded` says,
 * and every browser, tail, script, signal and request recorded instead of made.
 */
function fake(options: { loaded?: boolean; answers?: Record<string, CommandOutcome>; http?: (method: string, body: unknown) => HttpAnswer } = {}): Fake {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-cli-'));
  const home = path.join(dir, 'home');
  const state = path.join(dir, 'state');
  const config = path.join(dir, 'config.json');
  mkdirSync(home, { recursive: true });
  const lines: string[] = [];
  const calls: string[] = [];
  const alive = new Set<number>();
  const killed: number[] = [];
  const recorded: Pick<Fake, 'requests' | 'opened' | 'tailed' | 'scripts' | 'started'> = { requests: [], opened: [], tailed: [], scripts: [], started: [] };
  const deps: CliDependencies = {
    launchd: {
      launchctl: async (args) => {
        calls.push(args.join(' '));
        const verb = args[0] ?? '';
        if (verb === 'print') return options.loaded === true ? RUNNING : NOT_LOADED;
        return options.answers?.[verb] ?? OK;
      },
      files: {
        write: (file, text) => writeFileSync(file, text), remove: (file) => rmSync(file, { force: true }), exists: existsSync,
        read: (file) => readFileSync(file, 'utf8'), mkdir: (folder) => { mkdirSync(folder, { recursive: true }); }, privateFolder: (folder) => { mkdirSync(folder, { recursive: true }); },
      },
      portHolder: async () => null, waitForPort: async () => true, print: (line) => lines.push(line),
      env: { PATH: '/usr/bin:/bin', HOME: home }, uid: 501, home, node: '/opt/node/bin/node', daemon: path.join(home, '.local/share/brain-console/current/daemon/src/main.ts'),
      configPaths: { configFile: config, legacyProjectsFile: path.join(dir, 'projects.json') },
    },
    version: '0.7.0',
    defaultStateDir: state,
    cwd: dir,
    isAlive: (pid) => alive.has(pid),
    kill: (pid) => { killed.push(pid); alive.delete(pid); },
    sleep: async () => {},
    http: async (url, method, _token, body) => { recorded.requests.push({ method, url, body }); return options.http?.(method, body) ?? { status: 500, body: null }; },
    openUrl: async (url) => { recorded.opened.push(url); return 0; },
    tail: async (file, follow) => { recorded.tailed.push([file, follow]); return 0; },
    runScript: async (file, args) => { recorded.scripts.push([file, args]); return 0; },
    startDaemon: async (argv) => { recorded.started.push(argv); return 0; },
    listDirs: (folder) => { try { return readdirSync(folder, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name); } catch { return []; } },
  };
  return { deps, dir, home, state, config, lines, calls, alive, killed, ...recorded, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

/** A token in the state dir, as the daemon leaves it on its first start. */
function withToken(f: Fake): void {
  mkdirSync(f.state, { recursive: true });
  writeFileSync(path.join(f.state, 'token'), 's3cr3t\n');
}

/** A foreground daemon's pid file, its pid alive. */
function foreground(f: Fake, pid: number, port: number, argv: string[] = []): void {
  mkdirSync(f.state, { recursive: true });
  writeFileSync(pidFilePath(f.state), JSON.stringify({ pid, port, config: f.config, argv }));
  f.alive.add(pid);
}

/** The launch agent `install` would have written, with these start flags. */
function agent(f: Fake, flags: string[]): void {
  const plist = plistPath(f.home);
  mkdirSync(path.dirname(plist), { recursive: true });
  writeFileSync(plist, plistXml({ node: '/opt/node/bin/node', daemon: f.deps.launchd.daemon, flags, env: {}, log: path.join(f.state, 'daemon.log') }));
}

const configRoots = (f: Fake): string[] => (JSON.parse(readFileSync(f.config, 'utf8')) as { projects: { root: string }[] }).projects.map((entry) => entry.root);

test('Cli_NoSubcommand_PrintsTheHelp', async () => {
  const f = fake();
  try {
    assert.equal(await runCli([], f.deps), 0, 'because asking for nothing is not an error');
    assert.equal(f.lines.join('\n'), HELP, 'because no subcommand prints the help');
    for (const word of ['start', 'stop', 'restart', 'status', 'open', 'url', 'add <path>', 'remove <path>', 'logs [-f]', 'install', 'uninstall', 'update', 'version', 'help']) {
      assert.ok(HELP.includes(`\n  ${word}`), `because the help has a line for ${word}`);
    }
  } finally { f.cleanup(); }
});

test('Cli_UnknownSubcommand_ExitsTwoWithTheHelp', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['--project', '/x'], f.deps), 2, 'because flags alone are not a subcommand');
    assert.match(f.lines[0] ?? '', /unknown command --project/, 'because the owner hears what was not understood');
  } finally { f.cleanup(); }
});

test('Version_PrintsThePackageVersion', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['version'], f.deps), 0, 'because version always works');
    assert.deepEqual(f.lines, ['0.7.0'], 'because scripts read the bare version');
  } finally { f.cleanup(); }
});

test('Status_UnderLaunchd_NamesThePidPortUrlFilesAndVersion', async () => {
  const f = fake({ loaded: true });
  try {
    withToken(f);
    agent(f, ['--port', '7480', '--state-dir', f.state, '--config', f.config]);
    assert.equal(await runCli(['status'], f.deps), 0, 'because the job runs');
    assert.deepEqual(f.lines, [
      'brain-console 0.7.0', `daemon: loaded under launchd as ${LAUNCHD_LABEL}, pid 4242`, 'port: 7480',
      'url: http://127.0.0.1:7480/ (brain-console open adds the token)', `config: ${f.config}`, `state: ${f.state}`,
    ], 'because status reads the port and the files from the agent the job runs');
    assert.equal(f.lines.join('\n').includes('s3cr3t'), false, 'because status never prints the token');
  } finally { f.cleanup(); }
});

test('Status_ForegroundDaemon_FoundByItsPidFile', async () => {
  const f = fake();
  try {
    foreground(f, 77, 7481);
    assert.equal(await runCli(['status'], f.deps), 0, 'because a foreground daemon runs');
    assert.match(f.lines[1] ?? '', /running in the foreground, pid 77/, 'because the pid file names it');
    assert.equal(f.lines[2], 'port: 7481', 'because the port is the one it listens on, from the pid file');
  } finally { f.cleanup(); }
});

test('Status_StalePidFileAndNoJob_NotRunning', async () => {
  const f = fake();
  try {
    foreground(f, 77, 7481);
    f.alive.delete(77);
    assert.equal(await runCli(['status'], f.deps), 1, 'because nothing runs');
    assert.match(f.lines[1] ?? '', /^daemon: not running/, 'because a pid file whose process is gone is not a daemon');
    assert.equal(f.lines[2], 'port: 7474', 'because with nothing running the port is the default');
  } finally { f.cleanup(); }
});

test('Stop_UnderLaunchd_BootsTheJobOut', async () => {
  const f = fake({ loaded: true });
  try {
    assert.equal(await runCli(['stop'], f.deps), 0, 'because bootout succeeds');
    assert.deepEqual(f.calls, [`print gui/501/${LAUNCHD_LABEL}`, `bootout gui/501/${LAUNCHD_LABEL}`], 'because KeepAlive would start a killed job again, so stop unloads it');
  } finally { f.cleanup(); }
});

test('Stop_ForegroundDaemon_SignalledAndItsPidFileGone', async () => {
  const f = fake();
  try {
    foreground(f, 77, 7481);
    assert.equal(await runCli(['stop'], f.deps), 0, 'because the daemon ended');
    assert.deepEqual([f.killed, existsSync(pidFilePath(f.state))], [[77], false], 'because stop sends SIGTERM to the pid in the file and clears the file');
    assert.equal(f.calls.some((call) => call.startsWith('bootout')), false, 'because launchd has no job to stop');
  } finally { f.cleanup(); }
});

test('Stop_NothingRunning_SaysSoAndSucceeds', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['stop'], f.deps), 0, 'because stopping a stopped daemon is not an error');
    assert.deepEqual([f.lines, f.killed], [['brain-console: not running'], []], 'because nothing is signalled');
  } finally { f.cleanup(); }
});

test('Restart_UnderLaunchd_KickstartsTheJob', async () => {
  const f = fake({ loaded: true });
  try {
    assert.equal(await runCli(['restart'], f.deps), 0, 'because the job comes back on its port');
    assert.ok(f.calls.includes(`kickstart -k gui/501/${LAUNCHD_LABEL}`), 'because kickstart -k restarts the job in place, the current link picking the new version');
  } finally { f.cleanup(); }
});

test('Restart_ForegroundDaemon_StopsItAndStartsItHereWithItsFlags', async () => {
  const f = fake();
  try {
    foreground(f, 77, 7481, ['--port', '7481']);
    await runCli(['restart'], f.deps);
    assert.deepEqual([f.killed, f.started], [[77], [['--port', '7481']]], 'because a foreground daemon is replaced by one with the same flags');
  } finally { f.cleanup(); }
});

test('Restart_AgentWrittenButNotLoaded_BootstrapsIt', async () => {
  const f = fake();
  try {
    agent(f, []);
    await runCli(['restart'], f.deps);
    assert.ok(f.calls.includes(`bootstrap gui/501 ${plistPath(f.home)}`), 'because after stop the agent is still on disk and restart loads it again');
    assert.deepEqual(f.started, [], 'because nothing starts in the foreground');
  } finally { f.cleanup(); }
});

test('Url_WithAToken_PrintsItWithTheToken', async () => {
  const f = fake();
  try {
    withToken(f);
    assert.equal(await runCli(['url', '--port', '7480'], f.deps), 0, 'because the token is there');
    assert.deepEqual(f.lines, ['http://127.0.0.1:7480/?token=s3cr3t'], 'because scripts need the whole address and nothing else');
  } finally { f.cleanup(); }
});

test('Url_NoTokenYet_FailsSayingWhy', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['url'], f.deps), 1, 'because there is no address to give');
    assert.match(f.lines[0] ?? '', /no token/, 'because the owner hears the daemon has not started yet');
  } finally { f.cleanup(); }
});

test('Open_Running_OpensThePageWithTheToken', async () => {
  const f = fake({ loaded: true });
  try {
    withToken(f);
    agent(f, ['--port', '7480', '--state-dir', f.state]);
    assert.equal(await runCli(['open'], f.deps), 0, 'because the browser opened');
    assert.deepEqual(f.opened, ['http://127.0.0.1:7480/?token=s3cr3t'], 'because the page needs the token to read anything');
  } finally { f.cleanup(); }
});

test('Open_NotRunning_NoBrowser', async () => {
  const f = fake();
  try {
    withToken(f);
    assert.equal(await runCli(['open'], f.deps), 1, 'because there is no page to open');
    assert.deepEqual(f.opened, [], 'because a browser on a dead port helps nobody');
  } finally { f.cleanup(); }
});

test('Add_NothingRunning_WritesTheConfigFile', async () => {
  const f = fake();
  try {
    writeFileSync(f.config, JSON.stringify({ projects: [{ root: FIXTURE_ROOT }], terminal: 'ghostty' }));
    assert.equal(await runCli(['add', LOCAL_ROOT], f.deps), 0, 'because the folder holds a flow');
    assert.deepEqual(configRoots(f), [FIXTURE_ROOT, LOCAL_ROOT], 'because the new project is appended');
    assert.equal((JSON.parse(readFileSync(f.config, 'utf8')) as { terminal: string }).terminal, 'ghostty', 'because the other settings are kept');
  } finally { f.cleanup(); }
});

test('Add_RelativePath_ResolvedFromHere', async () => {
  const f = fake();
  try {
    f.deps.cwd = FIXTURES;
    assert.equal(await runCli(['add', 'project'], f.deps), 0, 'because ./project holds a flow');
    assert.deepEqual(configRoots(f), [FIXTURE_ROOT], 'because the root is stored absolute');
  } finally { f.cleanup(); }
});

test('Add_FolderWithoutAFlow_RefusedAndTheFileUnchanged', async () => {
  const f = fake();
  try {
    writeFileSync(f.config, JSON.stringify({ projects: [{ root: FIXTURE_ROOT }] }));
    assert.equal(await runCli(['add', f.dir], f.deps), 2, 'because Settings refuses a root with no .flow/config.yaml, and so does add');
    assert.match(f.lines[0] ?? '', /has no \.flow\/config\.yaml/, 'because the owner hears what is missing');
    assert.deepEqual(configRoots(f), [FIXTURE_ROOT], 'because a refused change writes nothing');
  } finally { f.cleanup(); }
});

test('Add_DaemonRunning_GoesThroughTheSettingsRoute', async () => {
  const f = fake({ http: (method, body) => (method === 'GET' ? { status: 200, body: { projects: { roots: [FIXTURE_ROOT], editable: true, note: null } } } : { status: 200, body }) });
  try {
    withToken(f);
    foreground(f, 77, 7481);
    assert.equal(await runCli(['add', LOCAL_ROOT], f.deps), 0, 'because the daemon took the change');
    assert.deepEqual(f.requests.map((request) => [request.method, request.url]), [['GET', 'http://127.0.0.1:7481/api/settings'], ['PUT', 'http://127.0.0.1:7481/api/settings']], 'because a running daemon checks, saves and applies the list itself, with no restart');
    assert.deepEqual(f.requests[1]?.body, { projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] }, 'because the PUT carries the whole new list');
    assert.equal(existsSync(f.config), false, 'because the daemon, not the command, writes the file');
  } finally { f.cleanup(); }
});

test('Add_DaemonProjectsFromFlags_RefusedWithTheDaemonsReason', async () => {
  const f = fake({ http: () => ({ status: 200, body: { projects: { roots: [FIXTURE_ROOT], editable: false, note: 'Set by --project when the daemon started.' } } }) });
  try {
    withToken(f);
    foreground(f, 77, 7481);
    assert.equal(await runCli(['add', LOCAL_ROOT], f.deps), 2, 'because projects set by a flag cannot change while it runs');
    assert.match(f.lines[0] ?? '', /Set by --project/, 'because the owner hears why');
    assert.equal(f.requests.length, 1, 'because nothing is PUT');
  } finally { f.cleanup(); }
});

test('Remove_NothingRunning_DropsTheRoot', async () => {
  const f = fake();
  try {
    writeFileSync(f.config, JSON.stringify({ projects: [{ root: FIXTURE_ROOT }, { root: LOCAL_ROOT }] }));
    assert.equal(await runCli(['remove', LOCAL_ROOT], f.deps), 0, 'because the root was watched');
    assert.deepEqual(configRoots(f), [FIXTURE_ROOT], 'because only that root goes');
  } finally { f.cleanup(); }
});

test('Remove_TheLastProject_Refused', async () => {
  const f = fake();
  try {
    writeFileSync(f.config, JSON.stringify({ projects: [{ root: FIXTURE_ROOT }] }));
    assert.equal(await runCli(['remove', FIXTURE_ROOT], f.deps), 2, 'because Settings keeps at least one project, and so does remove');
    assert.deepEqual(configRoots(f), [FIXTURE_ROOT], 'because the file is unchanged');
  } finally { f.cleanup(); }
});

test('Remove_NotWatched_Fails', async () => {
  const f = fake();
  try {
    writeFileSync(f.config, JSON.stringify({ projects: [{ root: FIXTURE_ROOT }] }));
    assert.equal(await runCli(['remove', LOCAL_ROOT], f.deps), 1, 'because there is nothing to remove');
  } finally { f.cleanup(); }
});

test('Add_NoPath_ExitsTwo', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['add'], f.deps), 2, 'because add needs a folder');
  } finally { f.cleanup(); }
});

test('Logs_Follow_TailsTheDaemonLogInTheStateDir', async () => {
  const f = fake();
  try {
    mkdirSync(f.state, { recursive: true });
    writeFileSync(path.join(f.state, 'daemon.log'), 'line\n');
    assert.equal(await runCli(['logs', '-f'], f.deps), 0, 'because the log is there');
    assert.deepEqual(f.tailed, [[path.join(f.state, 'daemon.log'), true]], 'because -f follows the log launchd writes');
  } finally { f.cleanup(); }
});

test('Logs_NoLog_SaysWhereAForegroundDaemonLogs', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['logs'], f.deps), 1, 'because there is no file');
    assert.match(f.lines[0] ?? '', /logs to its own terminal/, 'because a foreground daemon writes to its terminal, not the file');
  } finally { f.cleanup(); }
});

test('Start_NoDaemon_RunsItWithTheFlags', async () => {
  const f = fake();
  try {
    await runCli(['start', '--project', FIXTURE_ROOT, '--port', '7480'], f.deps);
    assert.deepEqual(f.started, [['--project', FIXTURE_ROOT, '--port', '7480']], 'because start is the daemon in the foreground, with the flags given');
  } finally { f.cleanup(); }
});

test('Start_ForegroundDaemonAlreadyRunning_Refused', async () => {
  const f = fake();
  try {
    foreground(f, 77, 7481);
    assert.equal(await runCli(['start'], f.deps), 1, 'because two daemons would share one state dir');
    assert.deepEqual(f.started, [], 'because nothing starts');
  } finally { f.cleanup(); }
});

test('Install_ThroughTheCli_WritesTheAgentForTheCurrentLink', async () => {
  const f = fake();
  try {
    f.deps.launchd.launchctl = async (args) => { f.calls.push(args.join(' ')); return args[0] === 'print' && f.calls.filter((call) => call.startsWith('print')).length > 1 ? RUNNING : args[0] === 'print' ? NOT_LOADED : OK; };
    assert.equal(await runCli(['install', '--project', FIXTURE_ROOT, '--state-dir', f.state, '--config', f.config], f.deps), 0, 'because the flags are valid');
    const plist = readFileSync(plistPath(f.home), 'utf8');
    assert.ok(plist.includes(`<string>${path.join(f.home, '.local/share/brain-console/current/daemon/src/main.ts')}</string>`), 'because the agent runs the current link, so an update needs only a restart');
  } finally { f.cleanup(); }
});

/** A console plugin of that version in a fake cache, with or without its install script. */
function cached(f: Fake, marketplace: string, version: string, script = true): string {
  const dir = path.join(f.home, '.claude', 'plugins', 'cache', marketplace, 'console', version);
  mkdirSync(path.join(dir, 'scripts'), { recursive: true });
  if (script) writeFileSync(path.join(dir, 'scripts', 'install.sh'), '#!/bin/sh\n');
  return dir;
}

test('Update_SeveralCachedVersions_RunsTheNewestInstallScriptWithoutLaunchd', async () => {
  const f = fake();
  try {
    cached(f, 'brain-plugins', '0.9.0');
    const newest = cached(f, 'brain-plugins', '0.10.0');
    cached(f, 'brain-plugins', '0.11.0', false);
    assert.equal(await runCli(['update'], f.deps), 0, 'because the script succeeded');
    assert.deepEqual(f.scripts, [[path.join(newest, 'scripts', 'install.sh'), ['--no-launchd']]], 'because 0.10.0 is newer than 0.9.0 by number, and a folder with no install script is not a plugin to install');
    assert.equal(f.calls.some((call) => call.startsWith('kickstart')), false, 'because no job is loaded to restart');
  } finally { f.cleanup(); }
});

test('Update_JobLoaded_RestartsItAfterTheInstall', async () => {
  const f = fake({ loaded: true });
  try {
    cached(f, 'brain-plugins', '0.7.0');
    await runCli(['update'], f.deps);
    assert.ok(f.calls.includes(`kickstart -k gui/501/${LAUNCHD_LABEL}`), 'because the agent runs the current link, so a restart runs the new version');
  } finally { f.cleanup(); }
});

test('Update_NothingCached_SaysHowToInstallThePlugin', async () => {
  const f = fake();
  try {
    assert.equal(await runCli(['update'], f.deps), 1, 'because there is nothing to install');
    assert.match(f.lines[0] ?? '', /claude plugin install console@brain-plugins/, 'because the owner hears the one command that fixes it');
    assert.equal(newestCachedPlugin(f.home, f.deps), null, 'because an empty cache has no plugin');
  } finally { f.cleanup(); }
});

test('DaemonEntry_InstalledCopy_IsTheCurrentLink', () => {
  const real = (file: string): string | null => ({ '/h/.local/share/brain-console/current/daemon/src/main.ts': '/h/.local/share/brain-console/0.7.0/daemon/src/main.ts', '/h/.local/share/brain-console/0.7.0/daemon/src/main.ts': '/h/.local/share/brain-console/0.7.0/daemon/src/main.ts' })[file] ?? file;
  assert.equal(daemonEntry('/h/.local/share/brain-console/0.7.0/daemon/src/main.ts', '/h', real), '/h/.local/share/brain-console/current/daemon/src/main.ts', 'because node resolves the link, but the agent must name the link');
  assert.equal(daemonEntry('/work/brain/plugins/console/app/daemon/src/main.ts', '/h', real), '/work/brain/plugins/console/app/daemon/src/main.ts', 'because a checkout runs itself');
});

test('CompareVersions_ByNumber', () => {
  assert.ok(compareVersions('0.10.0', '0.9.2') > 0, 'because 10 is more than 9');
  assert.equal(compareVersions('0.7.0', '0.7.0'), 0, 'because equal versions compare equal');
});

test('Status_AgentWrittenButNotLoaded_ShowsTheAgentsPort', async () => {
  const f = fake();
  try {
    agent(f, ['--port', '7481', '--state-dir', f.state]);
    assert.equal(await runCli(['status'], f.deps), 1, 'because nothing runs');
    assert.match(f.lines[1] ?? '', /brain-console restart loads it/, 'because the owner hears how to bring the stopped job back');
    assert.equal(f.lines[2], 'port: 7481', 'because restart would bring it back on the agent\'s port, not the default');
  } finally { f.cleanup(); }
});
