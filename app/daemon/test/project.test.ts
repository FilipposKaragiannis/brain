import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import type { Logger } from '../src/log.ts';
import { silentLogger } from '../src/log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from '../src/project.ts';
import type { CommandRunner } from '../src/collectors/exec.ts';
import { FIXTURES, FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LOCAL_ROOT = path.join(FIXTURES, 'project-local');

function localMonitor(log: Logger): ProjectMonitor {
  return new ProjectMonitor({ project: { id: 'local', name: 'local', root: LOCAL_ROOT }, runner: fakeRunner, clock: () => NOW, log, cadence: DEFAULT_CADENCE });
}

test('LocalAdapter_PullsFreshness_OkAndNotApplicable', async () => {
  const monitor = localMonitor(silentLogger);
  await monitor.refresh('files');
  await monitor.refresh('pulls');
  assert.deepEqual([monitor.snapshot?.sources.pulls.ok, monitor.snapshot?.sources.pulls.error], [true, 'not applicable: adapter local'], 'because a project off GitHub has no pull requests to read, which is not a failure');
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

/** The fixture runner, except that the plugin lookup every files read starts with waits until the test lets it go. */
function heldFilesRead(): { runner: CommandRunner; hold: () => void; release: () => void; noAgents: () => void } {
  let gate: Promise<void> | null = null;
  let open = (): void => {};
  let agents = true;
  const runner: CommandRunner = async (request) => {
    if (request.command === 'sh' && request.args[0] === '-c' && gate !== null) await gate;
    if (request.command === 'ps' && !agents) return { code: 0, stdout: '', stderr: '', timedOut: false };
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
  monitor.stop();
});
