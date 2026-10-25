import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { ActionContext } from '../src/actionPlan.ts';
import { ActionRunner, childProcessSpawner, realScheduler } from '../src/actions.ts';
import { silentLogger } from '../src/log.ts';
import type { ActionRecord } from '../src/snapshot.ts';
import { until } from './fakeSpawner.ts';

/** The flow plugin beside the console in this repository; its local adapter is the one the action runs. */
const FLOW_PLUGIN = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'flow');

test('StepSyncAction_LocalTracker_IssueTakesTheClaimsStep', { skip: !existsSync(path.join(FLOW_PLUGIN, 'adapters', 'local', 'write-state.sh')) && 'the flow plugin is not beside the console' }, async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'console-step-sync-'));
  try {
    mkdirSync(path.join(root, '.flow'));
    execFileSync('python3', ['-I', path.join(FLOW_PLUGIN, 'adapters', 'local', '_item.py'), 'create', path.join(root, '.flow'), 'task', 'One'], { cwd: root, stdio: 'ignore' });
    execFileSync('sh', [path.join(FLOW_PLUGIN, 'adapters', 'local', 'write-state.sh'), 'local:task/1', 'step=implement'], { cwd: root, stdio: 'ignore' });
    const worktree = path.join(root, 'wt');
    const context: ActionContext = {
      root, pluginRoot: FLOW_PLUGIN, repo: null, jobsHost: 'claude', pool: [worktree], outsideWorktrees: [], processCwds: [], sessions: [], terminal: null, installedTerminals: [], base: 'main',
      worktrees: [{ name: 'wt', path: worktree, item: 'local:task/1', claimBase: null, dirtyFiles: 0, behindBase: 0, agentPids: [], step: 'review', claimStep: 'review', trackerStep: 'implement' }],
      runItems: [], gateItems: [], worktreeSteps: { implement: true, review: true }, nextJob: null,
    };
    const refreshed: string[][] = [];
    const actions = new ActionRunner({ projectId: 'p', context: () => context, spawner: childProcessSpawner, scheduler: realScheduler, clock: () => new Date(), log: silentLogger, stateDir: path.join(root, 'state'), onRefresh: (sources) => { refreshed.push([...sources]); } });
    const outcome = actions.request('item.step-sync', { item: 'local:task/1' });
    assert.equal(outcome.status, 202, `because an item claimed at another step with no run going can take the claim's step: ${JSON.stringify(outcome.body)}`);
    const id = (outcome.body as { action: ActionRecord }).action.id;
    await until(() => actions.get(id)?.state !== 'running', 20000);
    const record = actions.get(id)!;
    assert.deepEqual([record.state, record.outcome], ['done', 'finished'], `because the write is over when the script ends: ${record.output ?? ''}`);
    const item = readFileSync(path.join(root, '.flow', 'items', 'task', '1.md'), 'utf8');
    assert.match(item, /^step: review$/m, "because the tracker now holds the claim's step");
    assert.match(item, /^last_event: .*step implement -> review, set by the console from the claim in wt/m, 'because the item says who moved it, as advance.sh leaves a last_event with every step change');
    assert.match(record.output ?? '', /from implement to review/, 'because the output names the old and the new step');
    await actions.whenIdle();
    assert.ok(refreshed.some((sources) => sources.includes('board') && sources.includes('files')), 'because the board and the files are read again so the row goes');
  } finally { rmSync(root, { recursive: true, force: true }); }
});
