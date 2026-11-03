import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { LogFields, Logger } from '../src/log.ts';
import { silentLogger } from '../src/log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from '../src/project.ts';
import type { CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import { BOARD_JSON, FIXTURES, FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LOCAL_ROOT = path.join(FIXTURES, 'project-local');

function localMonitor(log: Logger): ProjectMonitor {
  return new ProjectMonitor({ project: { id: 'local', name: 'local', root: LOCAL_ROOT }, runner: fakeRunner, clock: () => NOW, log, cadence: DEFAULT_CADENCE });
}

test('LocalAdapter_PullsFreshness_OkAndNotApplicable', async () => {
  const monitor = localMonitor(silentLogger);
  await monitor.refresh('files');
  await monitor.refresh('pulls');
  assert.deepEqual([monitor.snapshot?.sources.pulls.ok, monitor.snapshot?.sources.pulls.error], [true, 'not applicable: no github.repo in .flow/config.yaml'], 'because a project that names no repository has no pull requests to read, which is not a failure');
});

test('JiraTrackerWithGithubRepo_Pulls_ReadFromTheRepository', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-jira-pulls-'));
  try {
    cpSync(LOCAL_ROOT, dir, { recursive: true });
    writeFileSync(path.join(dir, '.flow', 'config.yaml'), 'adapters:\n  default: jira\ntrackers: [jira]\ngithub:\n  repo: example/fixture\njira:\n  site: https://acme.atlassian.net\n  project: WID\nbase: main\n');
    const monitor = new ProjectMonitor({ project: { id: 'jira', name: 'jira', root: dir }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
    await monitor.refresh('files');
    await monitor.refresh('pulls');
    assert.deepEqual([monitor.snapshot?.sources.pulls.ok, monitor.snapshot?.sources.pulls.error], [true, null], 'because the PRs of Jira items are on GitHub, so github.repo is read whatever tracker holds the items');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('TrackersReadGithubBesideALocalDefault_Pulls_GoOnToTheRepository', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-trackers-'));
  try {
    cpSync(LOCAL_ROOT, dir, { recursive: true });
    writeFileSync(path.join(dir, '.flow', 'config.yaml'), 'adapters:\n  default: local\ntrackers: [github, local]\nbase: main\n');
    const monitor = new ProjectMonitor({ project: { id: 'mixed', name: 'mixed', root: dir }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
    await monitor.refresh('files');
    await monitor.refresh('pulls');
    assert.equal(monitor.snapshot?.sources.pulls.error, 'not applicable: no github.repo in .flow/config.yaml', 'because the flow reads GitHub here, so only the missing repository stops the read');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('LocalAdapter_PullsRead_NothingWarned', async () => {
  const warnings: string[] = [];
  const monitor = localMonitor({ ...silentLogger, warn: (event) => { warnings.push(event); } });
  await monitor.refresh('files');
  await monitor.refresh('pulls');
  await monitor.refresh('pulls');
  assert.deepEqual(warnings, [], 'because a source that does not apply must not fill the log every minute');
});

const gateListDown: CommandRunner = async (request) =>
  request.command === 'sh' && request.args[0]?.endsWith('gate.sh') ? { code: 1, stdout: '', stderr: 'python3: command not found', timedOut: false } : fakeRunner(request);

test('GateListFails_FilesStayOkWithTheReason_WarnedOnce', async () => {
  const warnings: string[] = [];
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: gateListDown, clock: () => NOW, log: { ...silentLogger, warn: (event) => { warnings.push(event); } }, cadence: DEFAULT_CADENCE });
  await monitor.refresh('files');
  await monitor.refresh('files');
  assert.equal(monitor.snapshot?.sources.files.ok, true, 'because the gates, runs and claims were read; only the plugin\'s parse is missing');
  assert.equal(monitor.snapshot?.sources.files.error, 'gate questions: gate.sh list --json exited 1: python3: command not found', 'because the sources strip is where the owner learns why the card differs from Slack');
  assert.deepEqual(warnings, ['gates.list.failed'], 'because the same failure every 30 seconds must not fill the log');
  assert.equal(monitor.snapshot?.gates[0]?.questions.length, 2, 'because the daemon\'s own parse fills the card meanwhile');
});

function fixtureMonitor(): ProjectMonitor {
  return new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
}

const gateVsLabels = (monitor: ProjectMonitor): boolean =>
  (monitor.snapshot?.disagreements ?? []).some((entry) => entry.sources.join(' vs ') === 'gate record vs issue labels');

async function readEverySource(monitor: ProjectMonitor): Promise<void> {
  for (const source of ['files', 'git', 'processes', 'jobs', 'board', 'pulls'] as const) await monitor.refresh(source);
}

test('Monitor_DisagreementJustFound_HeldBack', async () => {
  const monitor = fixtureMonitor();
  await readEverySource(monitor);
  assert.equal(gateVsLabels(monitor), false, 'because the labels came from the board just now and the gate file may be newer than the last board read');
});

test('Monitor_DisagreementOnlyFasterSourcesRead_StillHeldBack', async () => {
  const monitor = fixtureMonitor();
  await readEverySource(monitor);
  await monitor.refresh('processes');
  await monitor.refresh('files');
  assert.equal(gateVsLabels(monitor), false, 'because the board has not been read again, so the labels may only be late');
});

test('Monitor_DisagreementHeldAfterBothStoresRead_Shown', async () => {
  const monitor = fixtureMonitor();
  await readEverySource(monitor);
  await monitor.refresh('files');
  await monitor.refresh('board');
  assert.equal(gateVsLabels(monitor), true, 'because the gate file and the labels were both read again and still disagree');
});

/** A ps listing that worked and holds no claude, codex or unattended loop. */
const NO_HOSTS = '    1 12-00:00:00 /sbin/launchd\n';

/** The fixture runner, except that the plugin lookup every files read starts with waits until the test lets it go. */
function heldFilesRead(): { runner: CommandRunner; hold: () => void; release: () => void; noAgents: () => void } {
  let gate: Promise<void> | null = null;
  let open = (): void => {};
  let agents = true;
  const runner: CommandRunner = async (request) => {
    if (request.command === 'sh' && request.args[0] === '-c' && gate !== null) await gate;
    if (request.command === 'ps' && !agents) return { code: 0, stdout: NO_HOSTS, stderr: '', timedOut: false };
    return fakeRunner(request);
  };
  return {
    runner,
    hold: () => { gate = new Promise((resolve) => { open = resolve; }); },
    release: () => { const wasOpen = open; gate = null; wasOpen(); },
    noAgents: () => { agents = false; },
  };
}

const deadRun = (monitor: ProjectMonitor): boolean =>
  (monitor.snapshot?.disagreements ?? []).some((entry) => entry.sources.join(' vs ') === 'run record vs process list');

test('Monitor_ReadInFlightWhenADisagreementAppears_DoesNotSettleIt', async () => {
  const held = heldFilesRead();
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: held.runner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
  await readEverySource(monitor);
  held.hold();
  const filesInFlight = monitor.refresh('files');
  held.noAgents();
  await monitor.refresh('processes');
  held.release();
  await filesInFlight;
  await monitor.refresh('processes');
  assert.equal(deadRun(monitor), false, 'because the files read that finished started before the agent was gone, so it says nothing about the run record since');
  await monitor.refresh('files');
  assert.equal(deadRun(monitor), true, 'because the next files read started after, and the run record is still there with no process');
});

test('Monitor_BoardFailing_DisagreementShownWithTheBoardRed', async () => {
  let boardFails = false;
  const runner: CommandRunner = async (request) =>
    boardFails && request.command === 'sh' && request.args[0]?.endsWith('board.sh') ? { code: 1, stdout: '', stderr: 'gh: rate limited', timedOut: false } : fakeRunner(request);
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
  await readEverySource(monitor);
  boardFails = true;
  await monitor.refresh('board');
  await monitor.refresh('files');
  assert.deepEqual([gateVsLabels(monitor), monitor.snapshot?.sources.board.ok], [true, false], 'because a board that keeps failing would hold the row back for ever, and the red board on the sources strip says how far to trust it');
});

test('ActionContext_PoolWorktreesRunsAndProcessFolders_FromTheLatestRead', async () => {
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
  await readEverySource(monitor);
  const context = monitor.actionContext();
  const wt3 = context.worktrees.find((worktree) => worktree.name === 'project-wt-3');
  assert.deepEqual([wt3?.item, wt3?.dirtyFiles, wt3?.agentPids], ['gh#9', 2, [100]], 'because a sync is refused on what the console shows: the claim, the dirty files and the agent in it');
  assert.deepEqual(context.runItems, ['gh#9'], 'because a run record holds its item against a merge');
  assert.ok(context.processCwds.includes(path.join(FIXTURES, 'project-wt-2', 'src')), 'because a session row may open a terminal in its own folder');
  assert.equal(context.processCwds.includes('/elsewhere'), false, 'because a codex working in another folder on the machine is not this project\'s to open');
  assert.deepEqual(context.outsideWorktrees.sort(), [FIXTURE_ROOT, path.join(FIXTURES, 'project-side')].sort(), 'because the main checkout and the side worktree git lists are rows with the button');
  monitor.stop();
});

/** The fixture monitor with ps and lsof answering as the test sets them (the fixture's answer while unset), and every log line kept. */
function lookupMonitor(): { monitor: ProjectMonitor; answer: { ps: CommandResult | null; lsof: CommandResult | null }; logged: Array<[string, LogFields]> } {
  const answer: { ps: CommandResult | null; lsof: CommandResult | null } = { ps: null, lsof: null };
  const runner: CommandRunner = async (request) => (request.command === 'ps' || request.command === 'lsof' ? answer[request.command] : null) ?? fakeRunner(request);
  const logged: Array<[string, LogFields]> = [];
  const keep = (event: string, fields: LogFields): void => { logged.push([event, fields]); };
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner, clock: () => NOW, log: { info: keep, warn: keep, error: keep }, cadence: DEFAULT_CADENCE });
  return { monitor, answer, logged };
}

const PS_TIMED_OUT: CommandResult = { code: null, stdout: '', stderr: '', timedOut: true };
const LSOF_EMPTY: CommandResult = { code: 1, stdout: '', stderr: '', timedOut: false };
const wt3Agents = (monitor: ProjectMonitor): number[] => monitor.snapshot?.worktrees.find((worktree) => worktree.name === 'project-wt-3')?.agents.map((agent) => agent.pid) ?? [];

test('Monitor_PsTimesOutOnce_LastAgentsStandAndTheRunIsNotDead', async () => {
  const { monitor, answer } = lookupMonitor();
  await readEverySource(monitor);
  answer.ps = PS_TIMED_OUT;
  await monitor.refresh('processes');
  assert.deepEqual([wt3Agents(monitor), monitor.snapshot?.runs[0]?.liveness], [[100], 'alive'], 'because a ps that timed out says nothing new, so the agent seen ten seconds ago still stands');
});

test('Monitor_PsTimesOut_ProcessesSourceRedWithTheReason', async () => {
  const { monitor, answer } = lookupMonitor();
  await readEverySource(monitor);
  answer.ps = PS_TIMED_OUT;
  await monitor.refresh('processes');
  assert.deepEqual([monitor.snapshot?.sources.processes.ok, monitor.snapshot?.sources.processes.error], [false, 'process list unavailable: ps timed out after 10s'], 'because the sources strip says the process list is missing and why');
});

test('Monitor_LsofMissesTheAgentOnce_AgentStaysWhereItWasSeen', async () => {
  const { monitor, answer } = lookupMonitor();
  await readEverySource(monitor);
  answer.lsof = LSOF_EMPTY;
  await monitor.refresh('processes');
  assert.deepEqual([wt3Agents(monitor), monitor.snapshot?.processList.status], [[100], 'partial'], 'because ps still lists pid 100, so only its directory is unknown this time, and it was in project-wt-3');
});

test('Monitor_LookupWorksAgain_ListCompleteAndSourceGreen', async () => {
  const { monitor, answer } = lookupMonitor();
  await readEverySource(monitor);
  answer.ps = PS_TIMED_OUT;
  await monitor.refresh('processes');
  answer.ps = null;
  await monitor.refresh('processes');
  assert.deepEqual([monitor.snapshot?.processList.status, monitor.snapshot?.sources.processes.ok, monitor.snapshot?.sources.processes.error], ['complete', true, null], 'because the next read that works restores the whole picture');
});

test('Monitor_RunProcessesGoneInAFullRead_RunDead', async () => {
  const { monitor, answer } = lookupMonitor();
  await readEverySource(monitor);
  answer.ps = { code: 0, stdout: NO_HOSTS, stderr: '', timedOut: false };
  await monitor.refresh('processes');
  assert.deepEqual([monitor.snapshot?.runs[0]?.liveness, monitor.snapshot?.worktrees.find((worktree) => worktree.name === 'project-wt-3')?.flags.includes('dead-run')], ['dead', true], 'because ps worked and lists neither the agent nor the owner, and the run started past the grace, so it is truly gone');
});

test('Monitor_LookupFailsTwice_LoggedOnceWithTheDiagnostics', async () => {
  const { monitor, answer, logged } = lookupMonitor();
  await readEverySource(monitor);
  answer.ps = PS_TIMED_OUT;
  await monitor.refresh('processes');
  await monitor.refresh('processes');
  const failed = logged.filter(([event]) => event === 'processes.lookup.failed').map(([, fields]) => [fields['command'], fields['timedOut'], fields['code'], fields['reason']]);
  assert.deepEqual(failed, [['ps', true, null, 'ps timed out after 10s']], 'because the log must say which lookup failed and how, once for a failure that lasts');
});

test('Monitor_LookupRecovers_RecoveryLogged', async () => {
  const { monitor, answer, logged } = lookupMonitor();
  await readEverySource(monitor);
  answer.lsof = LSOF_EMPTY;
  await monitor.refresh('processes');
  answer.lsof = null;
  await monitor.refresh('processes');
  assert.equal(logged.filter(([event]) => event === 'processes.lookup.recovered').length, 1, 'because the log shows how long an intermittent miss lasted');
});

/**
 * A copy of the fixture project whose gh#7, claimed in project-wt-2, waits at the merge gate and
 * names the pull given. Every `steward.sh` call is kept and answered with the codes given in turn;
 * a sweep that exits 0 clears the gate unless `keeps` says the worktree had to stay.
 */
function mergeGatedCopy(pr: string, codes: number[], keeps = false): { monitor: ProjectMonitor; root: string; sweeps: string[][]; cleanUp: () => void } {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-sweep-'));
  for (const name of ['project', 'project-wt-2']) cpSync(path.join(FIXTURES, name), path.join(dir, name), { recursive: true });
  const root = path.join(dir, 'project');
  rmSync(path.join(root, '.flow', 'gates', 'gh-7.json'));
  writeFileSync(path.join(root, '.flow', 'gates', 'gh-7.json'), JSON.stringify({ gate: 'merge', item: 'gh#7', message: 'Merge it', time: '2026-10-24T10:00:00Z', host: 'shell' }));
  const board = JSON.parse(BOARD_JSON) as { items: Array<{ id: string; state: Record<string, unknown> }> };
  for (const item of board.items) if (item.id === 'gh#7') item.state = { ...item.state, gate: 'merge', pr };
  const sweeps: string[][] = [];
  const runner: CommandRunner = async (request) => {
    const script = request.args[0] ?? '';
    if (request.command === 'sh' && script.endsWith('steward.sh')) {
      sweeps.push([request.cwd, ...request.args.slice(1)]);
      const code = codes.shift() ?? 0;
      if (code === 0 && !keeps) rmSync(path.join(root, '.flow', 'gates', 'gh-7.json'));
      return { code, stdout: 'gh#7: released project-wt-2 (#30 merged)\n', stderr: '', timedOut: false };
    }
    if (request.command === 'sh' && script.endsWith('gate.sh')) return { code: 0, stdout: '[]', stderr: '', timedOut: false };
    if (request.command === 'sh' && script.endsWith('board.sh')) return { code: 0, stdout: JSON.stringify(board), stderr: '', timedOut: false };
    return fakeRunner(request);
  };
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root }, runner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
  return { monitor, root, sweeps, cleanUp: () => rmSync(dir, { recursive: true, force: true }) };
}

test('MergeGatedPullLeftTheOpenList_SweptOnceForThatItem', async () => {
  const copy = mergeGatedCopy('https://github.com/example/fixture/pull/30', []);
  try {
    await readEverySource(copy.monitor);
    await copy.monitor.refresh('pulls');
    assert.deepEqual(copy.sweeps, [[copy.root, 'sweep', '--lock', '--item', 'gh#7']], 'because the merge is the owner\'s answer, so the gate clears within a pulls read, and once is enough');
  } finally { copy.cleanUp(); }
});

test('MergeGatedPullStillOpen_NotSwept', async () => {
  const copy = mergeGatedCopy('#560', []);
  try {
    await readEverySource(copy.monitor);
    assert.deepEqual(copy.sweeps, [], 'because #560 is still open, so nothing was merged');
  } finally { copy.cleanUp(); }
});

test('SweepLockHeld_SweptAgainOnTheNextPullsRead', async () => {
  const copy = mergeGatedCopy('#30', [75]);
  try {
    await readEverySource(copy.monitor);
    await copy.monitor.refresh('pulls');
    await copy.monitor.refresh('pulls');
    assert.equal(copy.sweeps.length, 2, 'because a sweep already running may have passed the item before the merge, so the next read tries once more, then stops');
  } finally { copy.cleanUp(); }
});

test('SweepKeptTheWorktree_SweptAgainOnTheNextPullsRead', async () => {
  const copy = mergeGatedCopy('#30', [], true);
  try {
    await readEverySource(copy.monitor);
    await copy.monitor.refresh('pulls');
    assert.equal(copy.sweeps.length, 2, 'because a sweep that kept a dirty worktree left the gate, so once the worktree is clean a later sweep must still clear it');
  } finally { copy.cleanUp(); }
});

test('SweepFails_NotRunAgain', async () => {
  const copy = mergeGatedCopy('#30', [1]);
  try {
    await readEverySource(copy.monitor);
    await copy.monitor.refresh('pulls');
    assert.equal(copy.sweeps.length, 1, 'because a sweep that fails would fail every minute; the health job sweeps again on its own schedule');
  } finally { copy.cleanUp(); }
});

test('PullOnAnItemsTaskBranch_ItemRecordedNoPr_SnapshotLinksTheItem', async () => {
  const board = JSON.parse(BOARD_JSON) as { items: Array<{ id: string; url: string }> };
  const twelve = board.items.find((item) => item.id === 'gh#12')!;
  board.items.push({ ...twelve, id: 'gh#310', url: 'https://example/310' });
  const runner: CommandRunner = async (request) =>
    request.command === 'sh' && (request.args[0] ?? '').endsWith('board.sh') ? { code: 0, stdout: JSON.stringify(board), stderr: '', timedOut: false } : fakeRunner(request);
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE });
  await readEverySource(monitor);
  assert.equal(monitor.snapshot?.pulls.find((pull) => pull.number === 560)?.item, 'gh#310', 'because #560 is opened from flow/gh-310, the task branch of gh#310, whose link-pr never recorded it');
  monitor.stop();
});

test('FilesRead_PluginReaderForTheRoot_SnapshotCarriesItsPlugins', async () => {
  const plugins = [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.27.1', codex: '1.27.0' }];
  const monitor = new ProjectMonitor({
    project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE,
    plugins: async (root) => (root === FIXTURE_ROOT ? plugins : []),
  });
  await monitor.refresh('files');
  assert.deepEqual(monitor.snapshot?.project.plugins, plugins, 'because a project-scope install is matched on the project root, and the header shows what the hosts have installed');
});

test('GitReadAfterTheFiles_PluginsNotReadAgain', async () => {
  const reads = [
    [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.27.1', codex: '1.27.0' }],
    [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.28.0', codex: '1.28.0' }],
  ];
  let next = 0;
  const monitor = new ProjectMonitor({
    project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE,
    plugins: async () => reads[Math.min(next++, reads.length - 1)]!,
  });
  await monitor.refresh('files');
  await monitor.refresh('git');
  assert.deepEqual(monitor.snapshot?.project.plugins, reads[0], 'because the plugins are read with the files, not on every snapshot build');
});

test('Monitor_RefreshNowWithNothingNew_StillSendsTheSnapshot', async () => {
  const monitor = fixtureMonitor();
  await readEverySource(monitor);
  let sent = 0;
  monitor.onChange(() => { sent += 1; });
  await monitor.refresh('git');
  assert.equal(sent, 0, 'because a timed read that finds nothing new stays quiet');
  await monitor.refreshNow(['git', 'board']);
  assert.equal(sent, 1, 'because a forced read must reach the page, so its new read times show');
});

test('Snapshot_NewerConsoleCached_CarriesTheNotice', async () => {
  const monitor = new ProjectMonitor({ project: { id: 'local', name: 'local', root: LOCAL_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE, newerConsole: () => ({ running: '0.9.2', cached: '0.10.0' }) });
  await monitor.refresh('files');
  assert.deepEqual(monitor.snapshot?.newerConsole, { running: '0.9.2', cached: '0.10.0' }, 'because the page shows the same notice as status while the versions differ');
});
