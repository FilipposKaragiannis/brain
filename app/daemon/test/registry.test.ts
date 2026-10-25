import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { ActionRunner, realScheduler } from '../src/actions.ts';
import { silentLogger } from '../src/log.ts';
import { ProjectMonitor } from '../src/project.ts';
import { ProjectRegistry } from '../src/registry.ts';
import type { ProjectSummary } from '../src/registry.ts';
import { FIXTURE_ROOT, FIXTURES, fakeRunner } from './fakeRunner.ts';
import { plainSpawner } from './fakeSpawner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const LONG_CADENCE = { filesMs: 600000, gitMs: 600000, processesMs: 600000, jobsMs: 600000, boardMs: 600000, pullsMs: 600000 };
const MAIN = { id: 'project', name: 'project', root: FIXTURE_ROOT };
const LOCAL = { id: 'project-local', name: 'project-local', root: path.join(FIXTURES, 'project-local') };

function registry() {
  const stopped: string[] = [];
  const { spawner } = plainSpawner();
  const projects = new ProjectRegistry((project) => {
    const monitor = new ProjectMonitor({ project, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: LONG_CADENCE });
    const stop = monitor.stop.bind(monitor);
    monitor.stop = () => { stopped.push(project.id); stop(); };
    const actions = new ActionRunner({ projectId: project.id, context: () => monitor.actionContext(), spawner, scheduler: realScheduler, clock: () => NOW, log: silentLogger, stateDir: os.tmpdir(), onRefresh: () => {} });
    return { monitor, actions };
  }, silentLogger);
  const heard: ProjectSummary[][] = [];
  projects.onChange((list) => heard.push(list));
  return { projects, stopped, heard };
}

test('Apply_NewRoot_MonitorStartedAndListHeard', async () => {
  const { projects, heard } = registry();
  try {
    await projects.apply([MAIN]);
    await projects.apply([MAIN, LOCAL]);
    assert.notEqual(projects.get('project-local')?.monitor.snapshot, null, 'because a root added in Settings is read without a restart');
    assert.deepEqual(heard.map((list) => list.map((project) => project.id)), [['project'], ['project', 'project-local']], 'because every change of the list reaches the listeners, the page among them');
  } finally { projects.stopAll(); }
});

test('Apply_RemovedRoot_MonitorStoppedAndDropped', async () => {
  const { projects, stopped } = registry();
  try {
    await projects.apply([MAIN, LOCAL]);
    await projects.apply([LOCAL]);
    assert.deepEqual([stopped, projects.get('project')], [['project'], undefined], 'because a removed project stops being read and its routes go away');
  } finally { projects.stopAll(); }
});

test('Apply_SameList_NothingHeard', async () => {
  const { projects, heard } = registry();
  try {
    await projects.apply([MAIN]);
    await projects.apply([MAIN]);
    assert.equal(heard.length, 1, 'because a save that leaves the projects alone must not restart their monitors');
  } finally { projects.stopAll(); }
});
