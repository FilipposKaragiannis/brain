import assert from 'node:assert/strict';
import { test } from 'node:test';
import { unlistedFolder } from '../src/actionPlan.ts';
import { paneEnvironment, parsePaneRequest, planPane } from '../src/panePlan.ts';
import type { PaneFacts, PaneHost, PaneRequest } from '../src/panePlan.ts';
import { DEFAULT_PANE_COLUMNS, DEFAULT_PANE_ROWS, MAX_PANE_COLUMNS, MAX_PANE_ROWS, MIN_PANE_COLUMNS, MIN_PANE_ROWS } from '../src/paneProtocol.ts';
import { codexModel } from '../src/plugins/flow/schema.ts';
import type { JobsPair } from '../src/plugins/flow/schema.ts';

const ROOT = '/p/app';
const POOL_WORKTREE = '/p/app-wt-2';
const OUTSIDE_WORKTREE = '/p/app-side';
const AGENT_FOLDER = '/p/app-wt-2/src';
const NO_PAIR: JobsPair = { model: null, effort: null, from: 'jobs' };
const FACTS: PaneFacts = { folders: [ROOT, POOL_WORKTREE, OUTSIDE_WORKTREE, AGENT_FOLDER], pairs: { claude: NO_PAIR, codex: NO_PAIR } };
const BINARIES: Record<string, string> = { claude: '/opt/tools/bin/claude', codex: '/usr/local/bin/codex' };
const HOST: PaneHost = { shell: '/bin/zsh', environment: {}, isFolder: () => true, executable: (name) => BINARIES[name] ?? null };
const SIZE = { columns: 132, rows: 41 };

function request(folder: string, run: PaneRequest['run'] = 'shell'): PaneRequest {
  return { folder, run, size: SIZE };
}

function withPairs(pairs: Partial<PaneFacts['pairs']>): PaneFacts {
  return { ...FACTS, pairs: { ...FACTS.pairs, ...pairs } };
}

function query(fields: Record<string, string>): URLSearchParams {
  return new URLSearchParams(fields);
}

test('ShellPane_ListedRoot_RunsTheOwnersLoginShellThere', () => {
  const plan = planPane(request(ROOT), FACTS, HOST);
  assert.deepEqual(plan, { ok: true, launch: { command: '/bin/zsh', args: ['-l'], workingFolder: ROOT } }, 'because a shell pane is the owner\'s login shell in the folder they picked');
});

test('ShellPane_EachListedSource_Planned', () => {
  for (const folder of [POOL_WORKTREE, OUTSIDE_WORKTREE, AGENT_FOLDER]) {
    const plan = planPane(request(folder), FACTS, HOST);
    assert.equal(plan.ok && plan.launch.workingFolder, folder, `because ${folder} is a folder the snapshot lists, as Open in Terminal allows`);
  }
});

test('ShellPane_UnlistedFolder_RefusedWithOpenInTerminalsWords', () => {
  assert.deepEqual(planPane(request('/etc'), FACTS, HOST), { ok: false, error: unlistedFolder('/etc') }, 'because a pane opens only where the snapshot lists a folder');
});

test('ShellPane_FolderBelowAListedOne_Refused', () => {
  assert.equal(planPane(request('/p/app/secrets'), FACTS, HOST).ok, false, 'because the allow-list names folders, not every folder under them');
});

test('ShellPane_RelativePath_Refused', () => {
  assert.equal(planPane(request('app'), { ...FACTS, folders: [...FACTS.folders, 'app'] }, HOST).ok, false, 'because a relative path depends on where the daemon runs');
});

test('ShellPane_ListedFolderMissingOnDisk_Refused', () => {
  const plan = planPane(request(POOL_WORKTREE), FACTS, { ...HOST, isFolder: (folder) => folder !== POOL_WORKTREE });
  assert.equal(plan.ok, false, 'because a configured pool worktree may not exist yet, and a pty cannot start there');
});

test('ClaudeSession_WithPair_RunsTheAbsoluteBinaryWithModelAndEffort', () => {
  const plan = planPane(request(ROOT, 'claude'), withPairs({ claude: { model: 'opus', effort: 'xhigh', from: 'jobs.claude' } }), HOST);
  assert.deepEqual(plan, { ok: true, launch: { command: '/opt/tools/bin/claude', args: ['--model', 'opus', '--effort', 'xhigh'], workingFolder: ROOT } }, 'because a quick session starts with the project\'s model and effort pair');
});

test('QuickSession_EmptyPair_NoFlag', () => {
  for (const run of ['claude', 'codex'] as const) {
    const plan = planPane(request(ROOT, run), FACTS, HOST);
    assert.deepEqual(plan.ok && plan.launch.args, [], `because an empty pair leaves ${run} on its own default`);
  }
});

test('ClaudeSession_EffortOnly_OnlyTheEffortFlag', () => {
  const plan = planPane(request(ROOT, 'claude'), withPairs({ claude: { model: null, effort: 'low', from: 'jobs.claude' } }), HOST);
  assert.deepEqual(plan.ok && plan.launch.args, ['--effort', 'low'], 'because each flag goes in only when its value is set');
});

test('CodexSession_RosterModel_CatalogNameAndReasoningEffort', () => {
  const plan = planPane(request(POOL_WORKTREE, 'codex'), withPairs({ codex: { model: 'opus', effort: 'high', from: 'jobs.codex' } }), HOST);
  assert.deepEqual(plan, { ok: true, launch: { command: '/usr/local/bin/codex', args: ['-m', codexModel('opus'), '-c', 'model_reasoning_effort="high"'], workingFolder: POOL_WORKTREE } }, 'because codex takes its catalog name and the effort as a config override');
});

test('CodexSession_CatalogModel_PassedThroughUnchanged', () => {
  const plan = planPane(request(ROOT, 'codex'), withPairs({ codex: { model: 'gpt-7-nova', effort: null, from: 'jobs.codex' } }), HOST);
  assert.deepEqual(plan.ok && plan.launch.args, ['-m', 'gpt-7-nova'], 'because a name that is not a roster name is already codex\'s own');
});

test('QuickSession_ModelOpeningWithDash_RefusedNamingTheKey', () => {
  const plan = planPane(request(ROOT, 'claude'), withPairs({ claude: { model: '--dangerously-skip-permissions', effort: null, from: 'jobs.claude' } }), HOST);
  assert.match(plan.ok ? '' : plan.error, /jobs\.claude\.model/, 'because a config value must never be read as a flag, and the owner needs the key to fix');
});

test('QuickSession_EffortTheHostDoesNotTake_RefusedNamingTheKey', () => {
  const plan = planPane(request(ROOT, 'codex'), withPairs({ codex: { model: null, effort: 'max', from: 'jobs.codex' } }), HOST);
  assert.match(plan.ok ? '' : plan.error, /jobs\.codex\.effort/, 'because codex has no max effort, and the owner needs the key to fix');
});

test('QuickSession_DeprecatedPair_RefusalNamesTheOldKey', () => {
  const plan = planPane(request(ROOT, 'claude'), withPairs({ claude: { model: null, effort: 'turbo', from: 'jobs' } }), HOST);
  assert.match(plan.ok ? '' : plan.error, /jobs\.effort/, 'because the bad value came from the deprecated jobs.effort key');
});

test('QuickSession_HostNotOnThePath_Refused', () => {
  const plan = planPane(request(ROOT, 'codex'), FACTS, { ...HOST, executable: () => null });
  assert.match(plan.ok ? '' : plan.error, /codex is not on the daemon's PATH/, 'because the daemon runs only a binary it found, and says which one is missing');
});

test('QuickSession_UnlistedFolder_RefusedBeforeTheBinary', () => {
  assert.deepEqual(planPane(request('/etc', 'claude'), FACTS, HOST), { ok: false, error: unlistedFolder('/etc') }, 'because the folder rule holds for an agent as for a shell');
});

test('Request_PathRunAndSize_Read', () => {
  assert.deepEqual(parsePaneRequest(query({ path: ROOT, run: 'codex', cols: '132', rows: '41' })), { ok: true, request: { folder: ROOT, run: 'codex', size: SIZE } }, 'because the page sends the folder, what to run and its terminal size');
});

test('Request_NoSize_DefaultSize', () => {
  const parsed = parsePaneRequest(query({ path: ROOT, run: 'shell' }));
  assert.deepEqual(parsed.ok && parsed.request.size, { columns: DEFAULT_PANE_COLUMNS, rows: DEFAULT_PANE_ROWS }, 'because a request that names no size gets the default terminal');
});

test('Request_SizeAtEachBound_Accepted', () => {
  const rows = [
    { columns: MIN_PANE_COLUMNS, rows: MIN_PANE_ROWS },
    { columns: MAX_PANE_COLUMNS, rows: MAX_PANE_ROWS },
  ];
  for (const size of rows) {
    const parsed = parsePaneRequest(query({ path: ROOT, run: 'shell', cols: String(size.columns), rows: String(size.rows) }));
    assert.deepEqual(parsed.ok && parsed.request.size, size, `because ${size.columns} by ${size.rows} is inside the bounds`);
  }
});

test('Request_SizeOutsideTheBounds_Refused', () => {
  const rows = [
    { cols: String(MIN_PANE_COLUMNS - 1), rows: '24' },
    { cols: String(MAX_PANE_COLUMNS + 1), rows: '24' },
    { cols: '80', rows: String(MIN_PANE_ROWS - 1) },
    { cols: '80', rows: String(MAX_PANE_ROWS + 1) },
    { cols: '80.5', rows: '24' },
    { cols: '-80', rows: '24' },
  ];
  for (const size of rows) {
    assert.equal(parsePaneRequest(query({ path: ROOT, run: 'shell', ...size })).ok, false, `because ${size.cols} by ${size.rows} is not a terminal the daemon will make`);
  }
});

test('Request_UnknownRun_Refused', () => {
  assert.equal(parsePaneRequest(query({ path: ROOT, run: 'bash -c id' })).ok, false, 'because a pane runs only a shell, claude or codex');
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
