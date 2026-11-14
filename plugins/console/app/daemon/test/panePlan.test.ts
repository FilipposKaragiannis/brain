import assert from 'node:assert/strict';
import { test } from 'node:test';
import { unlistedFolder } from '../src/actionPlan.ts';
import { paneEnvironment, parsePaneRequest, planPane } from '../src/panePlan.ts';
import type { PaneFacts, PaneHost, PaneRequest } from '../src/panePlan.ts';
import { DEFAULT_PANE_COLUMNS, DEFAULT_PANE_ROWS, MAXIMUM_PANE_COLUMNS, MAXIMUM_PANE_ROWS, MINIMUM_PANE_COLUMNS, MINIMUM_PANE_ROWS } from '../src/paneProtocol.ts';

const ROOT = '/p/app';
const POOL_WORKTREE = '/p/app-wt-2';
const OUTSIDE_WORKTREE = '/p/app-side';
const AGENT_FOLDER = '/p/app-wt-2/src';
const FACTS: PaneFacts = { folders: [ROOT, POOL_WORKTREE, OUTSIDE_WORKTREE, AGENT_FOLDER] };
const HOST: PaneHost = { shell: '/bin/zsh', environment: {}, isFolder: () => true };
const SIZE = { columns: 132, rows: 41 };

function request(folder: string, run: PaneRequest['run']): PaneRequest {
  return { folder, run, size: SIZE };
}

function query(fields: Record<string, string>): URLSearchParams {
  return new URLSearchParams(fields);
}

test('ShellPane_ListedRoot_RunsTheOwnersLoginShellThere', () => {
  const plan = planPane(request(ROOT, 'shell'), FACTS, HOST);
  assert.deepEqual(plan, { ok: true, launch: { command: '/bin/zsh', commandArguments: ['-l'], workingFolder: ROOT } }, 'because a shell pane is the owner\'s login shell in the folder they picked');
});

test('ShellPane_EachListedSource_Planned', () => {
  for (const folder of [POOL_WORKTREE, OUTSIDE_WORKTREE, AGENT_FOLDER]) {
    const plan = planPane(request(folder, 'shell'), FACTS, HOST);
    assert.equal(plan.ok && plan.launch.workingFolder, folder, `because ${folder} is a folder the snapshot lists, as Open in Terminal allows`);
  }
});

test('ShellPane_UnlistedFolder_RefusedWithOpenInTerminalsWords', () => {
  assert.deepEqual(planPane(request('/etc', 'shell'), FACTS, HOST), { ok: false, error: unlistedFolder('/etc') }, 'because a pane opens only where the snapshot lists a folder');
});

test('ShellPane_FolderBelowAListedOne_Refused', () => {
  assert.equal(planPane(request('/p/app/secrets', 'shell'), FACTS, HOST).ok, false, 'because the allow-list names folders, not every folder under them');
});

test('ShellPane_RelativePath_Refused', () => {
  assert.equal(planPane(request('app', 'shell'), { ...FACTS, folders: [...FACTS.folders, 'app'] }, HOST).ok, false, 'because a relative path depends on where the daemon runs');
});

test('ShellPane_ListedFolderMissingOnDisk_Refused', () => {
  const plan = planPane(request(POOL_WORKTREE, 'shell'), FACTS, { ...HOST, isFolder: (folder) => folder !== POOL_WORKTREE });
  assert.equal(plan.ok, false, 'because a configured pool worktree may not exist yet, and a pty cannot start there');
});

test('Request_PathRunAndSize_Read', () => {
  assert.deepEqual(parsePaneRequest(query({ path: ROOT, run: 'shell', cols: '132', rows: '41' })), { ok: true, request: { folder: ROOT, run: 'shell', size: SIZE } }, 'because the page sends the folder, what to run and its terminal size');
});

test('Request_NoSize_DefaultSize', () => {
  const parsed = parsePaneRequest(query({ path: ROOT, run: 'shell' }));
  assert.deepEqual(parsed.ok && parsed.request.size, { columns: DEFAULT_PANE_COLUMNS, rows: DEFAULT_PANE_ROWS }, 'because a request that names no size gets the default terminal');
});

test('Request_SizeAtEachBound_Accepted', () => {
  const sizes = [
    { columns: MINIMUM_PANE_COLUMNS, rows: MINIMUM_PANE_ROWS },
    { columns: MAXIMUM_PANE_COLUMNS, rows: MAXIMUM_PANE_ROWS },
  ];
  for (const size of sizes) {
    const parsed = parsePaneRequest(query({ path: ROOT, run: 'shell', cols: String(size.columns), rows: String(size.rows) }));
    assert.deepEqual(parsed.ok && parsed.request.size, size, `because ${size.columns} by ${size.rows} is inside the bounds`);
  }
});

test('Request_SizeOutsideTheBounds_Refused', () => {
  const sizes = [
    { cols: String(MINIMUM_PANE_COLUMNS - 1), rows: '24' },
    { cols: String(MAXIMUM_PANE_COLUMNS + 1), rows: '24' },
    { cols: '80', rows: String(MINIMUM_PANE_ROWS - 1) },
    { cols: '80', rows: String(MAXIMUM_PANE_ROWS + 1) },
    { cols: '80.5', rows: '24' },
    { cols: '-80', rows: '24' },
  ];
  for (const size of sizes) {
    assert.equal(parsePaneRequest(query({ path: ROOT, run: 'shell', ...size })).ok, false, `because ${size.cols} by ${size.rows} is not a terminal the daemon will make`);
  }
});

test('Request_UnknownRun_Refused', () => {
  assert.equal(parsePaneRequest(query({ path: ROOT, run: 'bash -c id' })).ok, false, 'because a pane runs only what the daemon knows by name');
});

test('Request_NoPath_Refused', () => {
  assert.equal(parsePaneRequest(query({ run: 'shell' })).ok, false, 'because a pane needs a folder to open in');
});

test('Environment_Tokens_NeverReachAPane', () => {
  const environment = paneEnvironment({ PATH: '/usr/bin', HOME: '/Users/owner', BRAIN_CONSOLE_TOKEN: 'console-secret', JIRA_API_TOKEN: 'jira-secret', AWS_SECRET_ACCESS_KEY: 'aws-secret' });
  assert.deepEqual(Object.values(environment).filter((value) => value.includes('secret')), [], 'because a pane inherits only the listed variables, never the daemon\'s secrets');
});

test('Environment_Basics_Inherited', () => {
  const environment = paneEnvironment({ PATH: '/opt/homebrew/bin:/usr/bin', HOME: '/Users/owner', SSH_AUTH_SOCK: '/tmp/agent.sock' });
  assert.deepEqual([environment['PATH'], environment['HOME'], environment['SSH_AUTH_SOCK']], ['/opt/homebrew/bin:/usr/bin', '/Users/owner', '/tmp/agent.sock'], 'because a login shell and git need the path, the home and the ssh agent');
});

test('Environment_Terminal_ColourTerminalSet', () => {
  const environment = paneEnvironment({ TERM: 'dumb' });
  assert.deepEqual([environment['TERM'], environment['COLORTERM']], ['xterm-256color', 'truecolor'], 'because the page draws with xterm.js, whatever terminal the daemon had');
});

test('Environment_LanguageUnset_Utf8', () => {
  assert.match(paneEnvironment({})['LANG'] ?? '', /UTF-8$/, 'because a terminal under launchd has no LANG, and agents print UTF-8');
});

test('Environment_LanguageSet_Kept', () => {
  assert.equal(paneEnvironment({ LANG: 'el_GR.UTF-8' })['LANG'], 'el_GR.UTF-8', 'because the owner\'s own language wins over the default');
});
