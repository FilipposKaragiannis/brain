import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { ActionRunner, KILL_GRACE_MS, OUTPUT_TAIL_CHARS } from '../src/actions.ts';
import { HANDED_ON_REFRESH_MS, SCRIPT_TIMEOUT_MS } from '../src/actionPlan.ts';
import type { ActionContext } from '../src/actionPlan.ts';
import { silentLogger } from '../src/log.ts';
import type { ActionRecord } from '../src/snapshot.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from '../src/project.ts';
import type { SourceName } from '../src/snapshot.ts';
import { FIXTURE_ROOT, fakeRunner } from './fakeRunner.ts';
import { fakeScheduler, fakeSpawner, plainSpawner, settle } from './fakeSpawner.ts';
import type { FakeSpawnerOptions } from './fakeSpawner.ts';

const CONTEXT: ActionContext = { root: '/p/app', pluginRoot: '/plugins/flow/1.17.0', repo: 'o/r', jobsHost: 'claude', pool: ['/p/app-wt-2', '/p/app-wt-3'] };
const NOW = new Date('2026-10-25T09:00:00Z');
const HTTP_ACCEPTED = 202;
const HTTP_BAD_REQUEST = 400;
const HTTP_CONFLICT = 409;
const SIGNAL_EXIT = 128;
const PLAIN: FakeSpawnerOptions = { failWith: null, detachedOutput: '' };

const actionOf = (outcome: { body: { action: ActionRecord } }): ActionRecord => outcome.body.action;

async function runner(context: ActionContext, options: FakeSpawnerOptions) {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), 'console-actions-'));
  const { spawner, processes } = fakeSpawner(options);
  const timers = fakeScheduler();
  const refreshed: string[][] = [];
  const events: ActionRecord[] = [];
  const actions = new ActionRunner({ projectId: 'app', context: () => context, spawner, scheduler: timers.scheduler, clock: () => NOW, log: silentLogger, stateDir, onRefresh: (sources) => refreshed.push(sources) });
  actions.onChange((record) => events.push(record));
  const auditLines = async (): Promise<ActionRecord[]> => { await actions.whenIdle(); return (await readFile(path.join(stateDir, 'app', 'actions.jsonl'), 'utf8')).trim().split('\n').map((line) => JSON.parse(line) as ActionRecord); };
  const cleanup = async (): Promise<void> => { await settle(); await actions.whenIdle(); await rm(stateDir, { recursive: true, force: true }); };
  return { actions, processes, timers, refreshed, events, stateDir, auditLines, cleanup };
}

test('Request_Accepted_ProcessStartsAtOnce', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const outcome = actions.request('gate.clear', { item: 'gh#268', message: 'yes' });
    assert.equal(outcome.status, HTTP_ACCEPTED, 'because a valid action is accepted at once');
    assert.equal(actionOf(outcome).state, 'running', 'because the process is already started when the reply leaves');
    assert.deepEqual(processes[0]?.plan.args, ['/plugins/flow/1.17.0/scripts/gate.sh', 'clear', 'gh#268', 'yes'], 'because the planned argv is what runs');
  } finally { await cleanup(); }
});

test('Request_ScriptEnvironment_MinimalAndLangC', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#268' });
    assert.equal(processes[0]?.env['LANG'], 'C', 'because scripts run in the minimal environment the collectors use');
  } finally { await cleanup(); }
});

test('ProcessExitsZero_Done_WithFullOutputBehindGet', async () => {
  const { actions, processes, events, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('gate.clear', { item: 'gh#268', message: 'yes' }));
    processes[0]!.stdout.write('gate cleared on gh#268\n');
    processes[0]!.exit(0, null);
    await settle();
    const done = actions.get(record.id)!;
    assert.equal(done.state, 'done', 'because exit 0 is done');
    assert.equal(done.output, 'gate cleared on gh#268\n', 'because the detail route carries the whole output');
    assert.equal(events.at(-1)?.state, 'done', 'because listeners hear the end');
  } finally { await cleanup(); }
});

test('ProcessEnds_SourcesItChanged_RefreshedOnce', async () => {
  const { actions, processes, refreshed, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#268' });
    processes[0]!.exit(0, null);
    await settle();
    assert.deepEqual(refreshed, [['files', 'board']], 'because a cleared gate changes the gate records and the tracker');
  } finally { await cleanup(); }
});

test('Action_AuditedAtStartAndAtEnd', async () => {
  const { actions, processes, stateDir, auditLines, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('gate.clear', { item: 'gh#268' }));
    processes[0]!.stdout.write('cleared\n');
    processes[0]!.exit(0, null);
    await settle();
    const lines = await auditLines();
    assert.deepEqual(lines.map((line) => line.state), ['running', 'done'], 'because a daemon that dies mid-action still leaves the start line');
    assert.equal('outputTail' in lines[1]!, false, 'because the audit line keeps the record, not the output');
    assert.equal(await readFile(path.join(stateDir, 'app', 'actions', `${record.id}.log`), 'utf8'), 'cleared\n', 'because the output sits beside the log');
  } finally { await cleanup(); }
});

test('OutputAfterExitBeforeClose_Kept', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('gate.clear', { item: 'gh#268' }));
    processes[0]!.lateOutput('from a grandchild\n');
    processes[0]!.exit(0, null);
    await settle();
    assert.equal(actions.get(record.id)?.output, 'from a grandchild\n', 'because the runner waits for close, not exit, so a grandchild\'s last words land');
  } finally { await cleanup(); }
});

test('ProcessExitsNonZero_Failed_WithStderrInOutput', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('worktree.release', { target: 'gh#5' }));
    processes[0]!.stderr.write('flow: no claimed worktree for gh#5\n');
    processes[0]!.exit(2, null);
    await settle();
    const ended = actions.get(record.id)!;
    assert.equal(ended.state, 'failed', 'because a non-zero exit is a failure');
    assert.equal(ended.exitCode, 2, 'because the steward exit codes carry meaning');
    assert.match(ended.output ?? '', /no claimed worktree/, 'because stderr joins the output');
  } finally { await cleanup(); }
});

test('LockHeld_SecondRequest_Conflict', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    const second = actions.request('run.start', { item: 'gh#1' });
    assert.equal(second.status, HTTP_CONFLICT, 'because gh#1 is held by the running gate.clear');
    assert.equal(actionOf(second).state, 'rejected', 'because the refused request is recorded too');
  } finally { await cleanup(); }
});

test('LockHeld_OtherItem_Accepted', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    assert.equal(actions.request('gate.clear', { item: 'gh#2' }).status, HTTP_ACCEPTED, 'because another item is free');
  } finally { await cleanup(); }
});

test('ProcessEnds_LockReleased', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    processes[0]!.exit(0, null);
    await settle();
    assert.equal(actions.request('gate.clear', { item: 'gh#1' }).status, HTTP_ACCEPTED, 'because the lock goes when the action ends');
  } finally { await cleanup(); }
});

test('UnknownKind_BadRequest', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    assert.equal(actions.request('rm.rf', {}).status, HTTP_BAD_REQUEST, 'because only the allow-listed kinds run');
  } finally { await cleanup(); }
});

test('NonStringArgs_BadRequest', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    assert.equal(actions.request('gate.clear', { item: 5 }).status, HTTP_BAD_REQUEST, 'because args are strings');
  } finally { await cleanup(); }
});

test('RefusedByPlanner_RecordedAsRejected', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const outcome = actions.request('gate.clear', { item: '' });
    assert.equal(outcome.status, HTTP_BAD_REQUEST, 'because the planner refused it');
    assert.equal(actions.list()[0]?.state, 'rejected', 'because a refused request still shows in the list');
  } finally { await cleanup(); }
});

test('Timeout_TermThenKill_Failed', async () => {
  const { actions, processes, timers, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('job.stop', { job: 'next' }));
    processes[0]!.ignoresTerm = true;
    assert.equal(timers.fire(SCRIPT_TIMEOUT_MS), 1, 'because a script carries the script timeout');
    assert.deepEqual(processes[0]!.signals, ['SIGTERM'], 'because the first attempt is polite');
    assert.equal(actions.get(record.id)?.state, 'running', 'because a shell with a trap may ignore SIGTERM');
    assert.equal(timers.fire(KILL_GRACE_MS), 1, 'because a grace timer follows the TERM');
    await settle();
    const ended = actions.get(record.id)!;
    assert.deepEqual(processes[0]!.signals, ['SIGTERM', 'SIGKILL'], 'because the process group is killed after the grace');
    assert.equal(ended.state, 'failed', 'because a timed out action never counts as done');
    assert.equal(ended.timedOut, true, 'because the record says why');
    assert.equal(ended.exitCode, SIGNAL_EXIT, 'because a signal exit is reported as 128');
  } finally { await cleanup(); }
});

test('TimeoutThenExitZero_StillFailed', async () => {
  const { actions, processes, timers, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('job.stop', { job: 'next' }));
    processes[0]!.ignoresTerm = true;
    timers.fire(SCRIPT_TIMEOUT_MS);
    processes[0]!.exit(0, null);
    await settle();
    assert.equal(actions.get(record.id)?.state, 'failed', 'because finishing late is not finishing');
  } finally { await cleanup(); }
});

test('SpawnThrows_FailedWithReason', async () => {
  const { actions, cleanup } = await runner(CONTEXT, { failWith: 'spawn sh ENOENT', detachedOutput: '' });
  try {
    const record = actionOf(actions.request('gate.clear', { item: 'gh#1' }));
    await settle();
    assert.equal(actions.get(record.id)?.state, 'failed', 'because a process that never started did nothing');
    assert.match(actions.get(record.id)?.output ?? '', /could not start: spawn sh ENOENT/, 'because the reason is in the output');
    assert.equal(actions.request('gate.clear', { item: 'gh#1' }).status, HTTP_ACCEPTED, 'because the lock was released');
  } finally { await cleanup(); }
});

test('RunStart_Detached_HoldsTheLockUntilTheRunEnds', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, { failWith: null, detachedOutput: 'step 1 done\nstep 2 done\n' });
  try {
    const record = actionOf(actions.request('run.start', { item: 'gh#9' }));
    assert.equal(processes[0]?.plan.detach, true, 'because the run outlives the daemon');
    assert.equal(actions.get(record.id)?.state, 'running', 'because the run is still going');
    assert.equal(actions.request('worktree.release', { target: 'gh#9', force: 'true' }).status, HTTP_CONFLICT, 'because the item is held for the life of the run, so nobody resets its worktree under the agent');
    processes[0]!.exit(0, null);
    await settle();
    const ended = actions.get(record.id)!;
    assert.equal(ended.state, 'done', 'because the run ended well');
    assert.match(ended.output ?? '', /started pid 4001/, 'because the pid lets the process list find it');
    assert.match(ended.output ?? '', /step 2 done/, 'because the run wrote its own file and the record reads it back');
  } finally { await cleanup(); }
});

test('RunStart_Detached_AuditNeverOverwritesTheRunsFile', async () => {
  const { actions, processes, stateDir, auditLines, cleanup } = await runner(CONTEXT, { failWith: null, detachedOutput: 'skipped: run 123 still going\n' });
  try {
    const record = actionOf(actions.request('run.start', { item: 'gh#9' }));
    processes[0]!.exit(0, null);
    await settle();
    await auditLines();
    assert.equal(await readFile(path.join(stateDir, 'app', 'actions', `${record.id}.log`), 'utf8'), 'skipped: run 123 still going\n', 'because the file is the run\'s, the audit only reads it');
  } finally { await cleanup(); }
});

test('Refresh_AsksTheMonitorWithoutAProcess', async () => {
  const { actions, processes, refreshed, cleanup } = await runner({ ...CONTEXT, pluginRoot: null }, PLAIN);
  try {
    const outcome = actions.request('refresh', { source: 'git' });
    assert.equal(outcome.status, HTTP_ACCEPTED, 'because refresh works without a plugin');
    assert.deepEqual(refreshed, [['git']], 'because one source was named');
    assert.equal(processes.length, 0, 'because nothing was spawned');
  } finally { await cleanup(); }
});

test('Refresh_UnknownSource_BadRequest', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    assert.equal(actions.request('refresh', { source: 'moon' }).status, HTTP_BAD_REQUEST, 'because an unknown source is refused');
  } finally { await cleanup(); }
});

test('List_NewestFirst_TailOnly', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    actions.request('gate.clear', { item: 'gh#2' });
    processes[0]!.stdout.write('x'.repeat(OUTPUT_TAIL_CHARS + 1000));
    processes[0]!.exit(0, null);
    await settle();
    const listed = actions.list();
    assert.equal(listed[0]?.args['item'], 'gh#2', 'because the newest request comes first');
    assert.equal(listed[1]?.outputTail.length, OUTPUT_TAIL_CHARS, 'because the list carries the tail only');
    assert.equal('output' in listed[1]!, false, 'because the full output waits behind the detail route');
  } finally { await cleanup(); }
});

test('StopAll_EndsAttachedActionsOnly', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    actions.request('gate.clear', { item: 'gh#1' });
    actions.request('run.start', { item: 'gh#2' });
    actions.stopAll();
    assert.deepEqual(processes.map((entry) => entry.signals), [['SIGTERM'], []], 'because a detached run must survive a daemon restart');
  } finally { await cleanup(); }
});

/**
 * A runner wired to a real monitor over the fixture project, as main.ts wires them, with a clock
 * the test moves: when a source was last read is the monitor's own state, not a recorder.
 */
async function wiredToMonitor() {
  const clock = { now: new Date('2026-10-25T09:00:00Z') };
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => clock.now, log: silentLogger, cadence: DEFAULT_CADENCE });
  await monitor.refresh('files');
  await monitor.refresh('jobs');
  const stateDir = await mkdtemp(path.join(os.tmpdir(), 'console-actions-'));
  const { spawner, processes } = plainSpawner();
  const timers = fakeScheduler();
  const actions = new ActionRunner({
    projectId: 'project', context: () => monitor.actionContext(), spawner, scheduler: timers.scheduler, clock: () => clock.now, log: silentLogger, stateDir,
    onRefresh: (sources) => { for (const source of sources) void monitor.refresh(source as SourceName); },
  });
  const jobsReadAt = (): string | null => monitor.snapshot?.sources.jobs.at ?? null;
  const later = (seconds: number): string => { clock.now = new Date(clock.now.getTime() + seconds * 1000); return clock.now.toISOString(); };
  const cleanup = async (): Promise<void> => { await settle(); await actions.whenIdle(); await rm(stateDir, { recursive: true, force: true }); };
  return { actions, processes, timers, jobsReadAt, later, cleanup };
}

test('JobRunEnds_JobsReadAgainAfterTheDelay', async () => {
  const { actions, processes, timers, jobsReadAt, later, cleanup } = await wiredToMonitor();
  try {
    actions.request('job.run', { job: 'comments' });
    later(1);
    processes[0]!.exit(0, null);
    await settle();
    const fiveSecondsOn = later(5);
    timers.fire(HANDED_ON_REFRESH_MS);
    await settle();
    assert.equal(jobsReadAt(), fiveSecondsOn, 'because the job launchd started shows in its status only a few seconds after jobs.sh returns, so the jobs are read again then');
  } finally { await cleanup(); }
});

test('StopAll_SecondReadWaiting_Dropped', async () => {
  const { actions, processes, timers, jobsReadAt, later, cleanup } = await wiredToMonitor();
  try {
    actions.request('job.run', { job: 'comments' });
    const ended = later(1);
    processes[0]!.exit(0, null);
    await settle();
    actions.stopAll();
    later(5);
    timers.fire(HANDED_ON_REFRESH_MS);
    await settle();
    assert.equal(jobsReadAt(), ended, 'because a daemon shutting down must not read sources after it stopped');
  } finally { await cleanup(); }
});

test('StopAll_HandOffEndsWellAfterTheStop_NoSecondRead', async () => {
  const { actions, processes, timers, jobsReadAt, later, cleanup } = await wiredToMonitor();
  try {
    actions.request('job.run', { job: 'comments' });
    processes[0]!.ignoresTerm = true;
    actions.stopAll();
    const ended = later(1);
    processes[0]!.exit(0, null);
    await settle();
    later(5);
    timers.fire(HANDED_ON_REFRESH_MS);
    await settle();
    assert.equal(jobsReadAt(), ended, 'because an action that ends after the stop must not start a read behind a stopped daemon');
  } finally { await cleanup(); }
});

test('JobRunFails_NoSecondRead', async () => {
  const { actions, processes, timers, jobsReadAt, later, cleanup } = await wiredToMonitor();
  try {
    actions.request('job.run', { job: 'comments' });
    const ended = later(1);
    processes[0]!.exit(1, null);
    await settle();
    later(5);
    timers.fire(HANDED_ON_REFRESH_MS);
    await settle();
    assert.equal(jobsReadAt(), ended, 'because a hand-off that failed started no job, so there is nothing to wait for');
  } finally { await cleanup(); }
});

test('JobRunExitsZero_DoneAndStarted', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('job.run', { job: 'comments' }));
    processes[0]!.exit(0, null);
    await settle();
    assert.equal(actions.get(record.id)?.outcome, 'started', 'because the job itself still runs under launchd, so done means started, not finished');
  } finally { await cleanup(); }
});

test('GateClearExitsZero_DoneAndFinished', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('gate.clear', { item: 'gh#1' }));
    processes[0]!.exit(0, null);
    await settle();
    assert.equal(actions.get(record.id)?.outcome, 'finished', 'because the gate is cleared when the script returns');
  } finally { await cleanup(); }
});

test('RunStartDetached_StartedWhileItRuns', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('run.start', { item: 'gh#9' }));
    assert.equal(actions.get(record.id)?.outcome, 'started', 'because the run goes on by itself from the moment its process exists');
  } finally { await cleanup(); }
});

test('ActionRunning_NoOutcomeYet', async () => {
  const { actions, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('gate.clear', { item: 'gh#1' }));
    assert.equal(actions.get(record.id)?.outcome, null, 'because an attached action has done nothing yet while it runs');
  } finally { await cleanup(); }
});

test('ActionFails_NoOutcome', async () => {
  const { actions, processes, cleanup } = await runner(CONTEXT, PLAIN);
  try {
    const record = actionOf(actions.request('job.run', { job: 'comments' }));
    processes[0]!.exit(1, null);
    await settle();
    assert.equal(actions.get(record.id)?.outcome, null, 'because a failed hand-off started nothing');
  } finally { await cleanup(); }
});
