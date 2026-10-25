import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { ActionRunner } from '../src/actions.ts';
import type { ActionContext } from '../src/actionPlan.ts';
import { silentLogger } from '../src/log.ts';
import type { ActionRecord } from '../src/snapshot.ts';
import { fakeSpawner, settle } from './fakeSpawner.ts';

const CONTEXT: ActionContext = { root: '/p/app', pluginRoot: '/plugins/flow/1.17.0', repo: 'o/r', jobsHost: 'claude' };
const NOW = new Date('2026-10-25T09:00:00Z');

async function runner(context: ActionContext = CONTEXT) {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), 'console-actions-'));
  const { spawner, processes } = fakeSpawner();
  const refreshed: string[][] = [];
  const events: ActionRecord[] = [];
  const actions = new ActionRunner({ projectId: 'app', context: () => context, spawner, clock: () => NOW, log: silentLogger, stateDir, onRefresh: (sources) => refreshed.push(sources) });
  actions.onChange((record) => events.push(record));
  return { actions, processes, refreshed, events, stateDir, cleanup: () => rm(stateDir, { recursive: true, force: true }) };
}

test('Request_StartsTheProcessAndStreamsItsOutput', async () => {
  const { actions, processes, events, refreshed, stateDir, cleanup } = await runner();
  try {
    const outcome = actions.request('gate.clear', { item: 'gh#268', message: 'yes' });
    assert.equal(outcome.status, 202, 'because a valid action is accepted at once');
    const record = (outcome.body as { action: ActionRecord }).action;
    assert.equal(record.state, 'running', 'because the process is already started when the reply leaves');
    assert.deepEqual(record.command, ['sh', '/plugins/flow/1.17.0/scripts/gate.sh', 'clear', 'gh#268', 'yes'], 'because the record shows what ran');
    assert.equal(processes[0]?.env['LANG'], 'C', 'because scripts run in the minimal environment');
    processes[0]!.stdout.write('gate cleared on gh#268\n');
    processes[0]!.exit(0);
    await settle();
    await actions.whenIdle();
    const done = actions.get(record.id)!;
    assert.equal(done.state, 'done', 'because exit 0 is done');
    assert.equal(done.exitCode, 0, 'because the exit code is kept');
    assert.equal(done.output, 'gate cleared on gh#268\n', 'because the detail route carries the whole output');
    assert.equal(done.outputBytes, 23, 'because the byte count is exact');
    assert.deepEqual(refreshed, [['files', 'board']], 'because the sources the action changed are re-read once');
    assert.equal(events.at(-1)?.state, 'done', 'because listeners hear the end');
    const audit = await readFile(path.join(stateDir, 'app', 'actions.jsonl'), 'utf8');
    assert.match(audit, /"kind":"gate.clear"/, 'because every finished action lands in the audit log');
    assert.equal(audit.includes('outputTail'), false, 'because the audit line keeps the record, not the output');
    assert.equal(await readFile(path.join(stateDir, 'app', 'actions', `${record.id}.log`), 'utf8'), 'gate cleared on gh#268\n', 'because the output sits beside the log');
  } finally { await cleanup(); }
});

test('Request_NonZeroExit_Failed', async () => {
  const { actions, processes, cleanup } = await runner();
  try {
    const record = (actions.request('steward.sweep', {}).body as { action: ActionRecord }).action;
    processes[0]!.stderr.write('flow: pool is busy\n');
    processes[0]!.exit(3);
    await settle();
    assert.equal(actions.get(record.id)?.state, 'failed', 'because a non-zero exit is a failure');
    assert.equal(actions.get(record.id)?.exitCode, 3, 'because the steward exit codes carry meaning');
    assert.match(actions.get(record.id)?.output ?? '', /pool is busy/, 'because stderr joins the output');
  } finally { await cleanup(); }
});

test('Request_WhileLockHeld_Conflict', async () => {
  const { actions, processes, cleanup } = await runner();
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    const second = actions.request('run.start', { item: 'gh#1' });
    assert.equal(second.status, 409, 'because gh#1 is held by the running gate.clear');
    assert.equal((second.body as { action: ActionRecord }).action.state, 'rejected', 'because the refused request is recorded too');
    const other = actions.request('gate.clear', { item: 'gh#2' });
    assert.equal(other.status, 202, 'because another item is free');
    processes[0]!.exit(0);
    await settle();
    assert.equal(actions.request('gate.clear', { item: 'gh#1' }).status, 202, 'because the lock is released when the action ends');
  } finally { await cleanup(); }
});

test('Request_UnknownKindOrBadArgs_BadRequest', async () => {
  const { actions, cleanup } = await runner();
  try {
    assert.equal(actions.request('rm.rf', {}).status, 400, 'because only the allow-listed kinds run');
    assert.equal(actions.request('gate.clear', { item: 5 }).status, 400, 'because args are strings');
    assert.equal(actions.request('gate.clear', { item: '' }).status, 400, 'because the planner refused it');
    assert.equal(actions.list().filter((record) => record.state === 'rejected').length, 1, 'because an unknown kind is dropped before a record exists and bad args make no plan, but a planned refusal is recorded');
  } finally { await cleanup(); }
});

test('Request_Timeout_KillsAndMarks', async () => {
  const { actions, processes, cleanup } = await runner();
  try {
    const record = (actions.request('job.stop', { job: 'next' }).body as { action: ActionRecord }).action;
    const timer = processes[0]!.plan.timeoutMs;
    assert.equal(timer, 120000, 'because a script gets two minutes');
    processes[0]!.exit(null, 'SIGTERM');
    await settle();
    const ended = actions.get(record.id)!;
    assert.equal(ended.state, 'failed', 'because a signal is not success');
    assert.equal(ended.exitCode, 128, 'because a signal exit is reported as 128');
    assert.match(ended.output ?? '', /SIGTERM/, 'because the output says what ended it');
  } finally { await cleanup(); }
});

test('RunStart_Detached_DoneAtOnceWithThePid', async () => {
  const { actions, processes, refreshed, cleanup } = await runner();
  try {
    const record = (actions.request('run.start', { item: 'gh#9' }).body as { action: ActionRecord }).action;
    await settle();
    assert.equal(processes[0]?.plan.detach, true, 'because the run outlives the request');
    assert.equal(actions.get(record.id)?.state, 'done', 'because starting it is the whole action');
    assert.match(actions.get(record.id)?.output ?? '', /started pid 4001/, 'because the pid lets the process list find it');
    assert.deepEqual(refreshed, [['files', 'processes']], 'because the run record and the process list change');
  } finally { await cleanup(); }
});

test('Refresh_AsksTheMonitorAndNeedsNoProcess', async () => {
  const { actions, processes, refreshed, cleanup } = await runner({ ...CONTEXT, pluginRoot: null });
  try {
    const outcome = actions.request('refresh', { source: 'git' });
    assert.equal(outcome.status, 202, 'because refresh works without a plugin');
    assert.deepEqual(refreshed, [['git']], 'because one source was named');
    assert.equal(processes.length, 0, 'because nothing was spawned');
    assert.equal(actions.request('refresh', { source: 'moon' }).status, 400, 'because an unknown source is refused');
  } finally { await cleanup(); }
});

test('List_NewestFirstWithoutOutput', async () => {
  const { actions, processes, cleanup } = await runner();
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    actions.request('gate.clear', { item: 'gh#2' });
    processes[0]!.stdout.write('x'.repeat(5000));
    processes[0]!.exit(0);
    await settle();
    const listed = actions.list();
    assert.equal(listed[0]?.args['item'], 'gh#2', 'because the newest request comes first');
    assert.equal(listed[1]?.outputTail.length, 4096, 'because the list carries the tail only');
    assert.equal('output' in listed[1]!, false, 'because the full output waits behind the detail route');
  } finally { await cleanup(); }
});
