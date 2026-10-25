import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import type { Logger } from '../src/log.ts';
import { silentLogger } from '../src/log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from '../src/project.ts';
import { FIXTURES, fakeRunner } from './fakeRunner.ts';

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
