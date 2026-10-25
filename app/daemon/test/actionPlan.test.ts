import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HANDED_ON_REFRESH_MS, planAction } from '../src/actionPlan.ts';
import type { ActionContext } from '../src/actionPlan.ts';

const CONTEXT: ActionContext = { root: '/p/app', pluginRoot: '/plugins/flow/1.17.0', repo: 'o/r', jobsHost: 'codex', pool: ['/p/app-wt-2', '/p/app-wt-3'] };

function planned(kind: Parameters<typeof planAction>[0], args: Record<string, string>, context = CONTEXT) {
  const result = planAction(kind, args, context);
  assert.equal(result.ok, true, `because ${kind} with ${JSON.stringify(args)} is a valid request`);
  return result.ok ? result.plan : assert.fail('unreachable');
}

test('GateClear_RunsGateScriptWithItemAndMessage', () => {
  const plan = planned('gate.clear', { item: 'gh#268', message: '1. yes\n2. the second one' });
  assert.deepEqual(plan.args, ['/plugins/flow/1.17.0/scripts/gate.sh', 'clear', 'gh#268', '1. yes\n2. the second one'], 'because the answer travels as one argv entry, never through a shell');
  assert.equal(plan.command, 'sh', 'because the scripts are POSIX sh');
  assert.equal(plan.cwd, '/p/app', 'because the flow scripts find the flow home from the cwd');
  assert.deepEqual(plan.locks, ['item:gh#268'], 'because two actions must not touch one item at once');
  assert.deepEqual(plan.refresh, ['files', 'board'], 'because a cleared gate changes the gate records and the tracker');
});

test('GateClear_WithoutMessage_OmitsTheArgument', () => {
  const plan = planned('gate.clear', { item: 'gh#1' });
  assert.deepEqual(plan.args.slice(1), ['clear', 'gh#1'], 'because the script fills its own default message');
});

test('GateClear_WithBadItem_Rejected', () => {
  for (const item of ['', '-rf', 'gh#1 x', '$(x)', 'github', 'local/../../tmp/x', 'local:7', 'src', 'gh#0']) {
    assert.equal(planAction('gate.clear', { item }, CONTEXT).ok, false, `because "${item}" is not an id an adapter owns, and the adapter name comes from the id prefix`);
  }
});

test('LocalItemId_Accepted', () => {
  assert.equal(planned('gate.clear', { item: 'local:task/7' }).args[2], 'local:task/7', 'because the local tracker names items kind/number');
});

test('UnknownArgument_Rejected', () => {
  const result = planAction('run.start', { Item: 'gh#9' }, CONTEXT);
  assert.equal(result.ok, false, 'because a typo must not quietly start the whole unattended queue');
  assert.match(result.ok ? '' : result.error, /does not take Item/, 'because the reason names the stray key');
});

test('RunStart_WithItem_DetachesTheNextJobOnTheConfiguredHost', () => {
  const plan = planned('run.start', { item: 'local:task/7' });
  assert.deepEqual(plan.args, ['/plugins/flow/1.17.0/jobs/next.sh', 'codex', 'local:task/7', '--max-steps', '15'], 'because jobs.host picks the CLI and the budget defaults to the next job default');
  assert.equal(plan.detach, true, 'because a run lasts far longer than a request');
  assert.equal(plan.timeoutMs, 0, 'because a detached run is never killed by the console');
  assert.deepEqual(plan.locks, ['item:local:task/7', 'job:next'], 'because next.sh with an item takes the next job lock too');
});

test('RunStart_WithoutItem_StartsTheScheduledNextJob', () => {
  const plan = planned('run.start', {});
  assert.deepEqual(plan.args.slice(1), ['run', 'next'], 'because jobs.sh run uses the schedule args and the job lock');
  assert.equal(plan.detach, false, 'because jobs.sh run returns as soon as the job is started');
});

test('RunStart_WithBadMaxSteps_Rejected', () => {
  assert.equal(planAction('run.start', { item: 'gh#1', maxSteps: '0' }, CONTEXT).ok, false, 'because zero steps is no run');
  assert.equal(planAction('run.start', { item: 'gh#1', maxSteps: '1000' }, CONTEXT).ok, false, 'because the budget caps at three digits');
  assert.equal(planAction('run.start', { maxSteps: '5' }, CONTEXT).ok, false, 'because the scheduled job has its own budget, so a stray maxSteps is not dropped quietly');
});

test('JobActions_MapToJobsScriptVerbs', () => {
  for (const [kind, verb] of [['job.run', 'run'], ['job.stop', 'stop'], ['job.pause', 'pause'], ['job.resume', 'resume']] as const) {
    const plan = planned(kind, { job: 'health' });
    assert.deepEqual(plan.args.slice(1), [verb, 'health'], `because ${kind} is jobs.sh ${verb}`);
    assert.deepEqual(plan.locks, ['job:health'], 'because one job takes one action at a time');
  }
  assert.equal(planAction('job.run', { job: 'Health' }, CONTEXT).ok, false, 'because job names are lower case words');
});

test('WorktreeRelease_ByPoolName_PassesThePath', () => {
  const plan = planned('worktree.release', { target: 'app-wt-2', force: 'true' });
  assert.deepEqual(plan.args.slice(1), ['release', '/p/app-wt-2', '--force'], 'because the steward resolves a bare name against the cwd, so the console hands it the pool path');
  assert.deepEqual(plan.locks, ['pool', 'worktree:/p/app-wt-2'], 'because the steward edits the pool and two stewards collide');
});

test('WorktreeRelease_ByItem_PassesTheItem', () => {
  assert.deepEqual(planned('worktree.release', { target: 'gh#5' }).args.slice(1), ['release', 'gh#5'], 'because the steward finds the claimed worktree for an item');
  assert.equal(planned('worktree.release', { target: 'gh#5', force: 'no' }).args.includes('--force'), false, 'because only the literal true forces');
});

test('WorktreeRelease_PathOrUnknownName_Rejected', () => {
  for (const target of ['src', 'src/../../other', '/p/app', '.', 'app-wt-9']) {
    assert.equal(planAction('worktree.release', { target }, CONTEXT).ok, false, `because "${target}" is neither an item nor a pool worktree, and the steward would detach whatever folder it names`);
  }
});

test('StewardHealth_RunsTheHealthJob', () => {
  const plan = planned('steward.health', {});
  assert.deepEqual(plan.args.slice(1), ['run', 'health'], 'because the job takes the health lock the scheduled run also takes, so two health passes never overlap');
  assert.deepEqual(plan.locks, ['job:health'], 'because the console lock mirrors the job');
});

test('PrMerge_UsesGhWithSquashByDefault', () => {
  const plan = planned('pr.merge', { pr: '41' });
  assert.equal(plan.command, 'gh', 'because the flow has no merge script yet');
  assert.deepEqual(plan.args, ['pr', 'merge', '41', '--repo', 'o/r', '--squash', '--delete-branch'], 'because squash is the house default and the branch goes with the PR');
  assert.deepEqual(planned('pr.merge', { pr: '41', method: 'rebase' }).args.includes('--rebase'), true, 'because the method can be chosen');
  assert.equal(planAction('pr.merge', { pr: '41', method: 'force' }, CONTEXT).ok, false, 'because only the three gh methods exist');
  assert.equal(planAction('pr.merge', { pr: '41' }, { ...CONTEXT, repo: null }).ok, false, 'because gh needs a repo');
  assert.deepEqual(plan.refresh, ['board', 'git', 'pulls'], 'because a merge changes the issue, the branches and the pull list');
});

test('AnyScriptAction_WithoutPlugin_Rejected', () => {
  const result = planAction('steward.health', {}, { ...CONTEXT, pluginRoot: null });
  assert.equal(result.ok, false, 'because there is no script to run');
  assert.match(result.ok ? '' : result.error, /plugin/, 'because the reason names the missing plugin');
});

test('Refresh_NeedsNoPluginAndNoProcess', () => {
  const plan = planned('refresh', { source: 'git' }, { ...CONTEXT, pluginRoot: null });
  assert.equal(plan.command, '', 'because refresh is handled inside the daemon');
});

test('JobRun_HandsTheJobOn_StartedAndReadAgainAfterFiveSeconds', () => {
  const plan = planned('job.run', { job: 'comments' });
  assert.deepEqual([plan.outcome, plan.refreshAgainMs], ['started', HANDED_ON_REFRESH_MS], 'because jobs.sh run returns once launchd has the job, and its run only shows a few seconds later');
});

test('StewardHealth_HandsTheHealthJobOn_StartedAndReadAgain', () => {
  const plan = planned('steward.health', {});
  assert.deepEqual([plan.outcome, plan.refreshAgainMs], ['started', HANDED_ON_REFRESH_MS], 'because it is jobs.sh run health, the same hand-off as job.run');
});

test('JobStop_FinishedAndReadOnce', () => {
  const plan = planned('job.stop', { job: 'next' });
  assert.deepEqual([plan.outcome, plan.refreshAgainMs], ['finished', null], 'because a stop is over when the script returns');
});
