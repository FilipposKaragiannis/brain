import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { silentLogger } from '../src/log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from '../src/project.ts';
import type { CommandRunner } from '../src/collectors/exec.ts';
import { FIXTURES, LOCAL_BOARD_JSON, fakeRunner } from './fakeRunner.ts';
import { noSubagents } from './fakeSubagents.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const ITEM = 'local:task/7';
const REPO_CONFIG = 'adapters:\n  default: local\nbase: main\ngithub:\n  repo: example/fixture\npool:\n  - ../project-wt-2\n';
const NO_REPO_CONFIG = 'adapters:\n  default: local\nbase: main\npool:\n  - ../project-wt-2\n';

type LocalProject = { monitor: ProjectMonitor; root: string; sweeps: string[][]; cleanUp: () => void };

/**
 * A project on the local tracker, as #121 met it: `adapters.default: local`, no `trackers`, and
 * the config given. local:task/7 is claimed in project-wt-2, waits at the merge gate and its `pr`
 * names the pull given. Every `steward.sh` call is kept, and a sweep clears the gate.
 */
function localTrackerProject(config: string, pr: string): LocalProject {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-local-pulls-'));
  for (const name of ['project', 'project-wt-2']) cpSync(path.join(FIXTURES, name), path.join(dir, name), { recursive: true });
  const root = path.join(dir, 'project');
  const gateFile = path.join(root, '.flow', 'gates', 'local-task-7.json');
  writeFileSync(path.join(root, '.flow', 'config.yaml'), config);
  rmSync(path.join(root, '.flow', 'gates', 'gh-7.json'));
  writeFileSync(gateFile, JSON.stringify({ gate: 'merge', item: ITEM, message: 'Merge it', time: '2026-10-24T10:00:00Z', host: 'shell' }));
  writeFileSync(path.join(dir, 'project-wt-2', '.flow', 'claim.json'), JSON.stringify({ item: ITEM, worktree: path.join(dir, 'project-wt-2'), name: 'project-wt-2', branch: 'flow/local-task-7', base: 'main', step: 'merge', claimed_at: '2026-10-24T09:00:00Z', host: 'shell' }));
  const board = JSON.parse(LOCAL_BOARD_JSON) as { items: Array<{ id: string; state: Record<string, unknown> }> };
  const template = board.items[0];
  board.items.push({ ...template, id: ITEM, state: { ...template?.state, step: 'merge', gate: 'merge', worktree: 'project-wt-2', pr } });
  const sweeps: string[][] = [];
  const runner: CommandRunner = async (request) => {
    const script = request.args[0] ?? '';
    if (request.command === 'sh' && script.endsWith('steward.sh')) {
      sweeps.push(request.args.slice(1));
      rmSync(gateFile, { force: true });
      return { code: 0, stdout: `${ITEM}: released project-wt-2 (#30 merged)\n`, stderr: '', timedOut: false };
    }
    if (request.command === 'sh' && script.endsWith('gate.sh')) return { code: 0, stdout: '[]', stderr: '', timedOut: false };
    if (request.command === 'sh' && script.endsWith('board.sh')) return { code: 0, stdout: JSON.stringify(board), stderr: '', timedOut: false };
    return fakeRunner(request);
  };
  const monitor = new ProjectMonitor({ project: { id: 'local', name: 'local', root }, runner, clock: () => NOW, log: silentLogger, cadence: DEFAULT_CADENCE, subagents: noSubagents });
  return { monitor, root, sweeps, cleanUp: () => rmSync(dir, { recursive: true, force: true }) };
}

async function readEverySource(monitor: ProjectMonitor): Promise<void> {
  for (const source of ['files', 'git', 'processes', 'jobs', 'board', 'pulls'] as const) await monitor.refresh(source);
}

async function withProject(config: string, pr: string, check: (project: LocalProject) => void | Promise<void>): Promise<void> {
  const project = localTrackerProject(config, pr);
  try {
    await readEverySource(project.monitor);
    await check(project);
  } finally { project.cleanUp(); }
}

test('LocalTrackerWithGithubRepo_PullsSource_ReadOk', async () => {
  await withProject(REPO_CONFIG, '#20', ({ monitor }) => {
    const pulls = monitor.snapshot?.sources.pulls;
    assert.deepEqual([pulls?.ok, pulls?.error], [true, null], 'because the flow opens a local item\'s PR on GitHub, so github.repo is read with no github tracker');
  });
});

test('LocalTrackerWithGithubRepo_PullRequests_ListTheOpenPulls', async () => {
  await withProject(REPO_CONFIG, '#20', ({ monitor }) => {
    assert.deepEqual(monitor.snapshot?.pulls.map((pull) => pull.number), [560, 20, 21, 22, 23], 'because the Pull requests tab lists every open PR of the repository');
  });
});

test('LocalTrackerWithGithubRepo_PullNamedByTheItem_LinkedToTheLocalItem', async () => {
  await withProject(REPO_CONFIG, '#20', ({ monitor }) => {
    const pull = monitor.snapshot?.pulls.find((entry) => entry.number === 20);
    assert.deepEqual([pull?.item, pull?.worktree], [ITEM, 'project-wt-2'], 'because the local item\'s pr field names #20, whichever tracker holds the item');
  });
});

test('LocalTrackerMergeGate_PullMergeable_CardCarriesThePull', async () => {
  await withProject(REPO_CONFIG, '#20', ({ monitor }) => {
    const gate = monitor.snapshot?.gates.find((entry) => entry.item === ITEM);
    assert.deepEqual([gate?.pull?.number, gate?.pull?.state], [20, 'mergeable'], 'because the card shows the PR chip and offers the Merge button only for a mergeable pull');
  });
});

test('LocalTrackerPullMergeable_NeedsYou_HasTheRowForTheLocalItem', async () => {
  await withProject(REPO_CONFIG, '#20', ({ monitor }) => {
    const row = monitor.snapshot?.attention.find((entry) => entry.kind === 'pr-mergeable');
    assert.equal(row?.id, ITEM, 'because a ready PR asks the owner to merge it, named by the local item that owns it');
  });
});

test('LocalTrackerMergeGate_PullLeftTheOpenList_SweptByTheMonitor', async () => {
  await withProject(REPO_CONFIG, '#30', ({ sweeps }) => {
    assert.deepEqual(sweeps, [['sweep', '--lock', '--item', ITEM]], 'because #30 is no longer open, so the merge landed and the monitor clears its gate at once');
  });
});

test('LocalTrackerWithoutGithubRepo_PullsSource_NotApplicable', async () => {
  await withProject(NO_REPO_CONFIG, '#20', ({ monitor }) => {
    const pulls = monitor.snapshot?.sources.pulls;
    assert.deepEqual([pulls?.ok, pulls?.error], [true, 'not applicable: no github.repo in .flow/config.yaml'], 'because only a missing repository stops the read, and that is not a failure');
  });
});
