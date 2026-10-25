import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HANDED_ON_REFRESH_MS, planAction, SYNC_SCRIPT } from '../src/actionPlan.ts';
import type { ActionContext, SyncFacts } from '../src/actionPlan.ts';

const CONTEXT: ActionContext = { root: '/p/app', pluginRoot: '/plugins/flow/1.17.0', repo: 'o/r', jobsHost: 'codex', pool: ['/p/app-wt-2', '/p/app-wt-3'], outsideWorktrees: ['/p/app-side'], processCwds: ['/p/app-wt-2/src'], terminal: null, installedTerminals: ['iterm'], base: 'main', worktrees: [], runItems: [] };

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

test('TerminalOpen_ProjectRoot_OpensItInTheFirstInstalledTerminal', () => {
  const plan = planned('terminal.open', { path: '/p/app' });
  assert.deepEqual([plan.command, ...plan.args], ['open', '-a', 'iTerm', '/p/app'], 'because with no terminal set the first installed one opens');
  assert.deepEqual([plan.locks, plan.refresh, plan.detach, plan.outcome], [[], [], false, 'finished'], 'because opening a window touches no flow state and is over when open returns');
});

test('TerminalOpen_PoolWorktreeAndAgentFolder_Allowed', () => {
  assert.equal(planned('terminal.open', { path: '/p/app-wt-3' }).args.at(-1), '/p/app-wt-3', 'because a pool worktree is a folder the console shows');
  assert.equal(planned('terminal.open', { path: '/p/app-wt-2/src' }).args.at(-1), '/p/app-wt-2/src', 'because an agent or session row opens where that process works');
});

test('TerminalOpen_AnyOtherPath_RefusedWithTheReason', () => {
  for (const target of ['/etc', '/p', '/p/app/../app-wt-9', 'p/app', '']) {
    const result = planAction('terminal.open', { path: target }, CONTEXT);
    assert.equal(result.ok, false, `because "${target}" is none of the folders the console lists`);
  }
  const result = planAction('terminal.open', { path: '/etc' }, CONTEXT);
  assert.match(result.ok ? '' : result.error, /not the project root, a worktree the console lists or the folder of a listed agent or session/, 'because the owner hears which folders may open');
});

test('TerminalOpen_EachNamedTerminal_ItsOwnCommand', () => {
  const opened = (terminal: 'iterm' | 'terminal' | 'ghostty') => { const plan = planned('terminal.open', { path: '/p/app' }, { ...CONTEXT, terminal }); return [plan.command, ...plan.args]; };
  assert.deepEqual(opened('terminal'), ['open', '-a', 'Terminal', '/p/app'], 'because Terminal opens a folder given to open -a');
  assert.deepEqual(opened('ghostty'), ['open', '-na', 'Ghostty', '--args', '--working-directory=/p/app'], 'because Ghostty takes the folder as an argument of a new instance');
  assert.deepEqual(opened('iterm'), ['open', '-a', 'iTerm', '/p/app'], 'because iTerm opens a folder given to open -a');
});

test('TerminalOpen_CustomCommand_PathSubstitutedInEachWord', () => {
  const plan = planned('terminal.open', { path: '/p/app-wt-2' }, { ...CONTEXT, terminal: { command: ['wezterm', 'start', '--cwd={path}'] } });
  assert.deepEqual([plan.command, ...plan.args], ['wezterm', 'start', '--cwd=/p/app-wt-2'], 'because the owner\'s command runs as argv with the folder in place');
});

test('TerminalOpen_CustomCommandWithoutPath_FolderLast', () => {
  const plan = planned('terminal.open', { path: '/p/app' }, { ...CONTEXT, terminal: { command: ['open', '-a', 'Warp'] } });
  assert.deepEqual(plan.args, ['-a', 'Warp', '/p/app'], 'because a command that never names the folder would open the wrong place');
});

test('TerminalOpen_NoTerminalInstalled_Refused', () => {
  const result = planAction('terminal.open', { path: '/p/app' }, { ...CONTEXT, installedTerminals: [] });
  assert.match(result.ok ? '' : result.error, /Settings/, 'because the owner must pick a terminal or a command there');
});

test('TerminalOpen_NoPlugin_StillPlanned', () => {
  assert.equal(planAction('terminal.open', { path: '/p/app' }, { ...CONTEXT, pluginRoot: null }).ok, true, 'because opening a folder runs no flow script');
});

test('TerminalOpen_Job_FollowsItsLogInTheProjectFlow', () => {
  const plan = planned('terminal.open', { path: '/p/app', job: 'next' }, { ...CONTEXT, terminal: 'ghostty' });
  assert.deepEqual(plan.args, ['-na', 'Ghostty', '--args', '--working-directory=/p/app', '-e', "cd '/p/app' && 'tail' '-n' '200' '-f' '/p/app/.flow/log/next.log'"], 'because a job row follows the job\'s log, the file jobs.sh logs reads, as one shell line that reads the same whether Ghostty runs it through a shell or joins its -e words');
});

test('TerminalOpen_JobFromAWorktreeOrBadName_Refused', () => {
  assert.equal(planAction('terminal.open', { path: '/p/app-wt-2', job: 'next' }, CONTEXT).ok, false, "because a job's log belongs to the project root");
  assert.equal(planAction('terminal.open', { path: '/p/app', job: '../../etc/passwd' }, CONTEXT).ok, false, 'because a job name never reaches outside .flow/log');
});

test('TerminalOpen_JobInITermAndTerminal_ThroughOsascript', () => {
  const iterm = planned('terminal.open', { path: '/p/app', job: 'health' });
  assert.deepEqual([iterm.command, iterm.args[1]], ['osascript', `tell application "iTerm" to create window with default profile command "/bin/sh -c 'cd '\\\\''/p/app'\\\\'' && '\\\\''tail'\\\\'' '\\\\''-n'\\\\'' '\\\\''200'\\\\'' '\\\\''-f'\\\\'' '\\\\''/p/app/.flow/log/health.log'\\\\'''"`], 'because iTerm runs its command without a shell, so the line goes to sh whole');
  const terminal = planned('terminal.open', { path: '/p/app', job: 'health' }, { ...CONTEXT, terminal: 'terminal' });
  assert.equal(terminal.args[1], `tell application "Terminal" to do script "cd '/p/app' && 'tail' '-n' '200' '-f' '/p/app/.flow/log/health.log'"`, 'because Terminal runs the line in its shell');
});

test('TerminalOpen_CustomCommandWithCmd_GetsTheQuotedLine', () => {
  const plan = planned('terminal.open', { path: '/p/app', job: 'next' }, { ...CONTEXT, terminal: { command: ['kitty', '--directory', '{path}', 'sh', '-c', '{cmd}'] } });
  assert.equal(plan.args.at(-1), `cd '/p/app' && 'tail' '-n' '200' '-f' '/p/app/.flow/log/next.log'`, 'because {cmd} is the line to run, quoted for sh');
});

const CLEAN: SyncFacts = { name: 'app-wt-2', path: '/p/app-wt-2', item: 'gh#7', claimBase: null, dirtyFiles: 0, agentPids: [] };
const SYNC: ActionContext = { ...CONTEXT, worktrees: [CLEAN, { ...CLEAN, name: 'app-wt-3', path: '/p/app-wt-3', item: 'gh#9', claimBase: 'epic/gh-300' }] };

test('WorktreeSync_ByName_MergesTheProjectBaseWithTheSyncScript', () => {
  const plan = planned('worktree.sync', { target: 'app-wt-2' }, SYNC);
  assert.deepEqual([plan.command, ...plan.args], ['sh', SYNC_SCRIPT, '/p/app-wt-2', 'main'], 'because the script fetches, merges the upstream and then the base, aborting on a conflict');
  assert.deepEqual([plan.locks, plan.refresh, plan.outcome, plan.detach], [['item:gh#7', 'worktree:/p/app-wt-2'], ['git'], 'finished', false], 'because a merge holds the item against a release by item or by name, and changes only git');
});

test('WorktreeSync_ByItem_MergesTheClaimsBase', () => {
  assert.deepEqual(planned('worktree.sync', { target: 'gh#9' }, SYNC).args.slice(1), ['/p/app-wt-3', 'epic/gh-300'], 'because the branch catches up with the base it was claimed from');
});

test('WorktreeSync_Dirty_RefusedWithItsReason', () => {
  const result = planAction('worktree.sync', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, dirtyFiles: 3 }] });
  assert.match(result.ok ? '' : result.error, /3 uncommitted files/, 'because a merge over uncommitted work could lose it');
});

test('WorktreeSync_RunRecordNamesTheItem_RefusedWithItsReason', () => {
  const result = planAction('worktree.sync', { target: 'gh#7' }, { ...SYNC, runItems: ['gh#7'] });
  assert.match(result.ok ? '' : result.error, /run record names gh#7/, 'because a run may be about to commit on that branch');
});

test('WorktreeSync_AgentInTheWorktree_RefusedWithItsReason', () => {
  const result = planAction('worktree.sync', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, agentPids: [100] }] });
  assert.match(result.ok ? '' : result.error, /agent works in app-wt-2 \(pid 100\)/, 'because an agent editing files there would see the merge land under it');
});

test('WorktreeSync_UnclaimedUnknownOrNotRead_Refused', () => {
  assert.match((r => r.ok ? '' : r.error)(planAction('worktree.sync', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, item: null }] })), /not claimed/, 'because a free worktree has no branch to bring up to date');
  assert.equal(planAction('worktree.sync', { target: 'app-wt-9' }, SYNC).ok, false, 'because only pool worktrees sync');
  assert.equal(planAction('worktree.sync', { target: '/p/app' }, SYNC).ok, false, 'because a path is not a target');
  assert.match((r => r.ok ? '' : r.error)(planAction('worktree.sync', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, dirtyFiles: null }] })), /not read/, 'because a worktree git has not read may be dirty');
});

test('WorktreeSync_BaseThatLooksLikeAnOption_Refused', () => {
  assert.equal(planAction('worktree.sync', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, claimBase: '--abort' }] }).ok, false, 'because a claim file must not hand git an option');
});

test('TerminalOpen_WorktreeOutsideThePool_Allowed', () => {
  assert.equal(planned('terminal.open', { path: '/p/app-side' }).args.at(-1), '/p/app-side', 'because the Worktrees screen shows a button on every outside row, and git lists that worktree for the project');
});

test('TerminalOpen_CustomCommandWithQpath_FolderQuotedForSh', () => {
  const plan = planned('terminal.open', { path: '/p/app' }, { ...CONTEXT, terminal: { command: ['sh', '-c', 'cd {qpath} && exec $SHELL'] } });
  assert.deepEqual(plan.args, ['-c', "cd '/p/app' && exec $SHELL"], 'because {qpath} is the folder quoted for an sh -c string, and the folder is not added again');
});
