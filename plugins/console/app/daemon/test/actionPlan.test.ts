import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ACTION_KINDS, HANDED_ON_REFRESH_MS, installNote, planAction, REVIEW_ASK, SYNC_SCRIPT, sweepNote } from '../src/actionPlan.ts';
import type { ActionContext, SyncFacts } from '../src/actionPlan.ts';

const CONTEXT: ActionContext = { root: '/p/app', pluginRoot: '/plugins/flow/1.17.0', pluginVersion: null, repo: 'o/r', jobsHost: 'codex', pool: ['/p/app-wt-2', '/p/app-wt-3'], outsideWorktrees: ['/p/app-side'], processCwds: ['/p/app-wt-2/src'], sessions: [], terminal: null, installedTerminals: ['iterm'], base: 'main', worktrees: [], runItems: [], gateItems: [], worktreeSteps: { implement: true, sync: true, plan: true, grill: false }, nextJob: { paused: false, running: false } };

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

test('GateClear_SentBack_PassesBackFlagBeforeMessage', () => {
  const plan = planned('gate.clear', { item: 'gh#268', message: 'split slice 2', back: 'true' });
  assert.deepEqual(plan.args.slice(1), ['clear', 'gh#268', '--back', 'split slice 2'], 'because gate.sh reads --back as the second argument and the message after it');
  assert.deepEqual(plan.locks, ['item:gh#268'], 'because sending back moves the item step like a clear does');
});

test('GateClear_SentBackWithoutMessage_Rejected', () => {
  for (const message of ['', '  ']) {
    assert.equal(planAction('gate.clear', { item: 'gh#268', message, back: 'true' }, CONTEXT).ok, false, 'because the step that runs again needs to know what to change');
  }
});

test('GateClear_BackNotTrueOrFalse_Rejected', () => {
  assert.equal(planAction('gate.clear', { item: 'gh#268', message: 'x', back: 'yes' }, CONTEXT).ok, false, 'because a loose flag must not decide between approving and sending back');
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
    assert.deepEqual(plan.locks, [kind === 'job.stop' ? 'stop:job:health' : 'job:health'], kind === 'job.stop' ? 'because a stop must reach a run that holds the job lock' : 'because one job takes one action at a time');
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

test('WorktreeReserve_WithoutName_RunsStewardReserve', () => {
  assert.deepEqual(planned('worktree.reserve', {}).args.slice(1), ['reserve'], "because the steward reserves under the owner's git user.name when no name is given");
});

test('WorktreeReserve_WithName_PassesItAsOneArgument', () => {
  assert.deepEqual(planned('worktree.reserve', { name: 'Ada Lovelace' }).args.slice(1), ['reserve', '--name', 'Ada Lovelace'], 'because a name with a space travels as one argv entry');
});

test('WorktreeReserve_HoldsThePoolLock', () => {
  assert.deepEqual(planned('worktree.reserve', {}).locks, ['pool'], 'because a reserve and a claim or release from the console must not pick the same worktree');
});

test('WorktreeReserve_BadName_Rejected', () => {
  for (const name of ['', '-x', '--force', 'a\nb', 'x'.repeat(65)]) {
    assert.equal(planAction('worktree.reserve', { name }, CONTEXT).ok, false, `because "${name}" is not a name: empty, read as an option, two lines or too long`);
  }
});

test('StewardSweep_RunsTheSweepUnderItsOwnLock', () => {
  assert.deepEqual(planned('steward.sweep', {}).args.slice(1), ['sweep', '--lock'], 'because --lock takes the sweep lock the next and health jobs take, and exits at once when one runs');
});

test('StewardSweep_HoldsThePoolAndTheHealthJobLocks', () => {
  assert.deepEqual(planned('steward.sweep', {}).locks, ['pool', 'job:health'], 'because a sweep releases worktrees as a release does, and the health job sweeps first');
});

test('StewardSweep_FinishedWithinTheScriptTimeout', () => {
  const plan = planned('steward.sweep', {});
  assert.deepEqual([plan.outcome, plan.detach], ['finished', false], 'because the sweep is over when the script returns, unlike the health job it is handed to');
});

test('SweepNote_ReleasedAndClearedLines_NameTheWorktreesAndTheGates', () => {
  const output = 'gh#5: cleared the merge gate\ngh#5: released app-wt-2 (https://github.com/o/r/pull/41 merged)\nlocal:task/7: released app-wt-3 (local:task/7 is closed)\n';
  assert.equal(sweepNote(output), 'freed app-wt-2 (gh#5), app-wt-3 (local:task/7); cleared the merge gate of gh#5', 'because the owner pressed Sweep to see what it freed');
});

test('SweepNote_KeptWorktreeOnly_NothingLanded', () => {
  assert.equal(sweepNote('gh#5: kept app-wt-2, it has uncommitted changes (gh#5 is closed)\n'), 'nothing landed: no worktree freed, no gate cleared', 'because a kept worktree was not freed');
});

test('SweepNote_LockHeld_SaysASweepRunsAlready', () => {
  assert.equal(sweepNote('flow: sweep skipped: the sweep lock is held\n'), 'a sweep is running already, so this one did nothing', 'because exit 75 alone does not say why');
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

test('PrReview_AsksOneReviewerThroughComments', () => {
  const plan = planned('pr.review', { pr: '41', reviewer: '@codex' });
  assert.deepEqual(plan.args.slice(1), ['request-review', '41', REVIEW_ASK, 'codex'], 'because comments.sh posts the mention with the request marker the health job tracks, and takes the name without its @');
  assert.match(plan.args[0] ?? '', /scripts\/comments\.sh$/, 'because the flow owns how a reviewer is asked');
  assert.deepEqual(plan.locks, ['pr:41'], 'because an ask and a merge of one PR never overlap');
  assert.equal(planAction('pr.review', { pr: '41', reviewer: 'bad name' }, CONTEXT).ok, false, 'because a name with a space would mention someone else');
  assert.equal(planAction('pr.review', { pr: '41' }, CONTEXT).ok, false, 'because an ask needs someone to ask');
  assert.equal(planAction('pr.review', { pr: '41', reviewer: 'codex' }, { ...CONTEXT, repo: null }).ok, false, 'because the ask is a GitHub comment');
  assert.equal(planAction('pr.review', { pr: '41', reviewer: 'codex' }, { ...CONTEXT, pluginVersion: '1.26.0' }).ok, false, 'because flow 1.26.0 ignores the name and would ask every reviewer');
  assert.equal(planAction('pr.review', { pr: '41', reviewer: 'codex' }, { ...CONTEXT, pluginVersion: '1.27.0' }).ok, true, 'because 1.27.0 asks the one named');
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

const CLEAN: SyncFacts = { name: 'app-wt-2', path: '/p/app-wt-2', item: 'gh#7', claimBase: null, dirtyFiles: 0, behindBase: 27, agentPids: [], step: 'implement', claimStep: 'implement', trackerStep: 'implement' };
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

const refusal = (result: ReturnType<typeof planAction>): string => (result.ok ? '' : result.error);

test('SyncHandoff_ValidTarget_StartsTheItemsRunAsRunStartDoes', () => {
  const plan = planned('sync.handoff', { target: 'app-wt-2', refs: 'origin/main' }, SYNC);
  const { prepare, ...rest } = plan;
  assert.deepEqual(rest, planned('run.start', { item: 'gh#7' }, SYNC), 'because the run is the one run.start starts for the item: detached, the item and next-job locks, the same re-reads');
  assert.equal(typeof prepare, 'function', 'because the note is written in the daemon once the locks are held, before the run starts');
});

test('SyncHandoff_UpToDateWithoutRefs_RefusedNothingToHandOff', () => {
  const result = planAction('sync.handoff', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, behindBase: 0 }] });
  assert.match(refusal(result), /no merge to hand off/, 'because a sync step with nothing to merge would only spend a run');
});

test('SyncHandoff_UpToDateWithRefs_Accepted', () => {
  const result = planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/flow/gh-7' }, { ...SYNC, worktrees: [{ ...CLEAN, behindBase: 0 }] });
  assert.equal(result.ok, true, "because a conflict with the branch's own upstream is owed even when the base is merged");
});

test('SyncHandoff_DirtyWorktree_RefusedAsSyncIs', () => {
  const result = planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/main' }, { ...SYNC, worktrees: [{ ...CLEAN, dirtyFiles: 2 }] });
  assert.match(refusal(result), /has 2 uncommitted files; commit or stash them before merging/, 'because the sync step would merge over uncommitted work, and the health job drops a note for a dirty tree');
});

test('SyncHandoff_ItemAtAGate_RefusedWithItsReason', () => {
  const result = planAction('sync.handoff', { target: 'gh#7', refs: 'origin/main' }, { ...SYNC, gateItems: ['gh#7'] });
  assert.match(refusal(result), /gh#7 waits at a gate/, 'because next.sh exits at a gate before any step, and the health job then drops the note');
});

test('SyncHandoff_StepOutsideTheWorktree_RefusedWithItsReason', () => {
  const result = planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/main' }, { ...SYNC, worktrees: [{ ...CLEAN, step: 'grill' }] });
  assert.match(refusal(result), /step grill, which runs outside the worktree/, 'because next.sh runs the sync step only ahead of a worktree step');
  assert.match(refusal(planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/main' }, { ...SYNC, worktreeSteps: null })), /step table could not be read/, 'because an unknown step table cannot say the sync runs first');
});

test('SyncHandoff_NextJobPausedOrRunning_RefusedWithItsReason', () => {
  assert.match(refusal(planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/main' }, { ...SYNC, nextJob: { paused: true, running: false } })), /next job is paused/, 'because a paused next job exits at once and the note would wait unread');
  assert.match(refusal(planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/main' }, { ...SYNC, nextJob: { paused: false, running: true } })), /next job run is going/, 'because a run while the next job holds its lock is skipped');
});

test('SyncHandoff_RunRecordNamesTheItem_RefusedWithItsReason', () => {
  const result = planAction('sync.handoff', { target: 'gh#7', refs: 'origin/main' }, { ...SYNC, runItems: ['gh#7'] });
  assert.match(refusal(result), /run record names gh#7; its run is going/, 'because a second run of the item would race the first');
});

test('SyncHandoff_AgentInTheWorktree_RefusedWithItsReason', () => {
  const result = planAction('sync.handoff', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, agentPids: [100] }] });
  assert.match(refusal(result), /agent works in app-wt-2 \(pid 100\)/, 'because a run started under a working agent would mix with its work');
});

test('SyncHandoff_BadTargetOrRefs_Refused', () => {
  assert.match(refusal(planAction('sync.handoff', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, item: null }] })), /not claimed/, 'because a free worktree has no item to run');
  assert.match(refusal(planAction('sync.handoff', { target: 'app-wt-2' }, { ...SYNC, worktrees: [{ ...CLEAN, behindBase: null }] })), /not read/, 'because a worktree git has not read may have nothing to merge');
  for (const refs of ['--abort', 'origin/main\n../x', 'a b', '']) {
    assert.equal(planAction('sync.handoff', { target: 'app-wt-2', refs }, SYNC).ok, false, `because ${JSON.stringify(refs)} is not a list of refs git can merge`);
  }
  assert.equal(planAction('sync.handoff', { target: 'app-wt-2' }, { ...SYNC, pluginRoot: null }).ok, false, 'because without the plugin there is no run to start');
});

test('SyncHandoff_RefsOnePerLine_Accepted', () => {
  assert.equal(planAction('sync.handoff', { target: 'app-wt-2', refs: 'origin/flow/gh-7\norigin/main\n' }, SYNC).ok, true, 'because the UI passes the conflict record\'s refs one per line, as the note holds them');
});

test('WorktreeSync_ConflictOutput_RecordCarriesTheConflict', () => {
  const plan = planned('worktree.sync', { target: 'app-wt-2' }, SYNC);
  assert.deepEqual(plan.conflict?.('console: merging origin/main conflicts, so the merge was aborted. Conflicting files:\na.txt\nconsole: still to merge: origin/main\n'), { refs: ['origin/main'], files: ['a.txt'] }, 'because the record carries the conflict for the hand-off');
});

test('TerminalOpen_WorktreeOutsideThePool_Allowed', () => {
  assert.equal(planned('terminal.open', { path: '/p/app-side' }).args.at(-1), '/p/app-side', 'because the Worktrees screen shows a button on every outside row, and git lists that worktree for the project');
});

test('TerminalOpen_CustomCommandWithQpath_FolderQuotedForSh', () => {
  const plan = planned('terminal.open', { path: '/p/app' }, { ...CONTEXT, terminal: { command: ['sh', '-c', 'cd {qpath} && exec $SHELL'] } });
  assert.deepEqual(plan.args, ['-c', "cd '/p/app' && exec $SHELL"], 'because {qpath} is the folder quoted for an sh -c string, and the folder is not added again');
});

test('JobsInstall_RunsJobsShInstallHoldingEveryJobLock', () => {
  const plan = planned('jobs.install', {});
  assert.deepEqual([plan.command, ...plan.args], ['sh', '/plugins/flow/1.17.0/scripts/jobs.sh', 'install'], 'because install writes and loads the schedule of every job jobs.schedule names');
  assert.deepEqual(plan.locks, ['job:next', 'job:comments', 'job:intake', 'job:retro', 'job:health'], 'because a reload must not race a run, stop or pause of any job');
  assert.deepEqual([plan.outcome, plan.refresh], ['finished', ['jobs']], 'because the schedule is loaded when the script returns, and the jobs list shows it');
});

test('JobsInstall_WithAJob_Refused', () => {
  assert.equal(planAction('jobs.install', { job: 'next' }, CONTEXT).ok, false, 'because the console reloads the whole schedule, never one job of it');
});

test('JobsInstall_ARunningJobLeftAsItIs_TheNoteNamesIt', () => {
  const plan = planned('jobs.install', {});
  const output = 'next: running now, left as it is; install it again after the run\ncomments: every 10m, as com.app.flow.comments\n';
  assert.equal(plan.note?.(output), 'skipped next: running now, so it keeps the old schedule; install again after the run', 'because jobs.sh exits 0 when it skips a running job, and done alone would say the schedule was reloaded');
  assert.equal(installNote('comments: every 10m, as com.app.flow.comments\n'), null, 'because a clean install needs no note');
});

test('JobUninstall_RunsJobsShUninstallForThatJob', () => {
  const plan = planned('job.uninstall', { job: 'retro' });
  assert.deepEqual([plan.args.slice(1), plan.locks, plan.refresh], [['uninstall', 'retro'], ['job:retro'], ['jobs']], 'because a job whose schedule left the config is unloaded on its own; install never touches it again');
  assert.equal(planAction('job.uninstall', { job: 'all' }, CONTEXT).ok, false, 'because the console unloads one named job, never every job at once');
});

/** gh#7 claimed in app-wt-2 at step review while the issue says implement, with no run of it going. */
const STEP_SYNC: ActionContext = { ...CONTEXT, worktrees: [{ ...CLEAN, claimStep: 'review', trackerStep: 'implement', step: 'review' }] };
const stepSyncError = (context: ActionContext, item = 'gh#7'): string => { const result = planAction('item.step-sync', { item }, context); return result.ok ? '' : result.error; };

test('StepSync_GithubItem_WritesTheClaimsStepThroughTheAdapter', () => {
  const plan = planned('item.step-sync', { item: 'gh#7' }, STEP_SYNC);
  assert.deepEqual([plan.command, ...plan.args.slice(0, 3)], ['sh', '/plugins/flow/1.17.0/adapters/github/write-state.sh', 'gh#7', 'step=review'], "because `adapter write-state` runs the item's adapter's write-state.sh with the item first, as advance.sh calls it");
  assert.match(plan.args[3] ?? '', /^last_event=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ step implement -> review, set by the console from the claim in app-wt-2$/, 'because advance.sh writes last_event with every step change, and this one must say the console set it');
  assert.deepEqual([plan.cwd, plan.locks, plan.refresh, plan.outcome, plan.detach], ['/p/app', ['item:gh#7'], ['board', 'files'], 'finished', false], 'because the write holds the item, is over when the script ends, and changes the tracker');
});

test('StepSync_LocalItem_UsesTheLocalAdapter', () => {
  const context: ActionContext = { ...CONTEXT, worktrees: [{ ...CLEAN, item: 'local:task/7', claimStep: 'review', trackerStep: 'implement' }] };
  assert.equal(planned('item.step-sync', { item: 'local:task/7' }, context).args[0], '/plugins/flow/1.17.0/adapters/local/write-state.sh', "because lib/flow.sh's adapter_for picks the adapter from the id's prefix");
});

test('StepSync_Prepare_OutputNamesOldAndNewStep', async () => {
  const prepared = await planned('item.step-sync', { item: 'gh#7' }, STEP_SYNC).prepare?.();
  assert.match(prepared?.output ?? '', /from implement to review/, 'because the owner must see which step was replaced by which');
  assert.deepEqual(prepared?.event, { name: 'item.step-sync', fields: { item: 'gh#7', worktree: '/p/app-wt-2', from: 'implement', to: 'review' } }, 'because the change is one log line');
});

test('StepSync_RunRecordNamesTheItem_Refused', () => {
  assert.match(stepSyncError({ ...STEP_SYNC, runItems: ['gh#7'] }), /run record names gh#7/, 'because a going run moves the step itself');
});

test('StepSync_AgentInTheWorktree_Refused', () => {
  assert.match(stepSyncError({ ...STEP_SYNC, worktrees: [{ ...STEP_SYNC.worktrees[0]!, agentPids: [100] }] }), /agent works in app-wt-2 \(pid 100\)/, 'because an agent at work moves the step itself');
});

test('StepSync_ClaimWithoutStep_Refused', () => {
  assert.match(stepSyncError({ ...STEP_SYNC, worktrees: [{ ...STEP_SYNC.worktrees[0]!, claimStep: '' }] }), /records no step/, 'because there is nothing to set the issue to');
});

test('StepSync_ClaimAtSyncStep_Refused', () => {
  assert.match(stepSyncError({ ...STEP_SYNC, worktrees: [{ ...STEP_SYNC.worktrees[0]!, claimStep: 'sync' }] }), /sync step/, "because the sync step runs ahead of the item's own step and never moves it");
});

test('StepSync_ClaimStepNotAStepName_Refused', () => {
  assert.match(stepSyncError({ ...STEP_SYNC, worktrees: [{ ...STEP_SYNC.worktrees[0]!, claimStep: 'review gate=none' }] }), /not a step name/, 'because a claim file must not write other state fields into the tracker');
});

test('StepSync_UnclaimedOrBadItem_Refused', () => {
  assert.deepEqual([stepSyncError(STEP_SYNC, 'gh#9') !== '', stepSyncError(STEP_SYNC, '7') !== ''], [true, true], 'because only an item claimed in the pool has a claim to take the step from');
});

test('StepSync_IssueAlreadyAgrees_Refused', () => {
  assert.match(stepSyncError({ ...STEP_SYNC, worktrees: [{ ...STEP_SYNC.worktrees[0]!, trackerStep: 'review' }] }), /already says/, 'because there is nothing left to settle');
});

test('HostClear_RunsGateClearWithTheHost', () => {
  const plan = planned('host.clear', { host: 'claude' });
  assert.deepEqual(plan.args, ['/plugins/flow/1.17.0/scripts/gate.sh', 'clear', 'claude'], 'because gate.sh clear <host> removes <flow home>/log/<host>.stopped');
  assert.deepEqual([plan.cwd, plan.locks, plan.refresh, plan.outcome], ['/p/app', ['host:claude'], ['files'], 'finished'], 'because two clears of one host must not race, and the files source reads the stopped hosts with the gates');
});

test('HostClear_NotAHost_Rejected', () => {
  for (const host of ['', 'gh#7', 'Claude', 'shell', '-rf']) {
    assert.equal(planAction('host.clear', { host }, CONTEXT).ok, false, `because "${host}" is not a host flow stops, and gate.sh clear would read an item id as a gate to clear`);
  }
});

test('ActionKinds_JobStartAndHostClear_Accepted', () => {
  assert.ok(ACTION_KINDS.includes('job.start') && ACTION_KINDS.includes('host.clear'), 'because the server refuses a kind the list does not hold');
});

test('JobStart_EveryOption_PassedToTheProjectsNextJobAndDetached', () => {
  const plan = planned('job.start', { job: 'next', host: 'claude', workers: '3', maxSteps: '20', model: 'claude-opus-4-1', effort: 'max' });
  assert.deepEqual(plan.args, ['/p/app/.flow/jobs/next.sh', 'claude', '--workers', '3', '--max-steps', '20', '--model', 'claude-opus-4-1', '--effort', 'max'], 'because next.sh takes the host first and the options as flags, each one argv entry');
  assert.deepEqual([plan.command, plan.cwd, plan.detach, plan.timeoutMs], ['sh', '/p/app', true, 0], 'because a run lasts far longer than a request and is never killed by the console');
  assert.deepEqual(plan.locks, ['job:next'], 'because the run takes the next job lock');
  assert.deepEqual(plan.refresh, ['jobs', 'processes', 'files', 'board'], 'because a run changes the jobs, the agents, the run records and the tracker');
});

test('JobStartWithAnItem_ItemAfterTheHostAndLocked', () => {
  const plan = planned('job.start', { job: 'next', host: 'codex', item: 'gh#12', effort: 'xhigh' });
  assert.deepEqual(plan.args.slice(1), ['codex', 'gh#12', '--effort', 'xhigh'], 'because next.sh reads the item after the host');
  assert.deepEqual(plan.locks, ['item:gh#12', 'job:next'], 'because the item is worked too, as run.start locks it');
  assert.deepEqual([plan.outcome, plan.refreshAgainMs], ['finished', null], 'because one session runs in the started process');
});

test('JobStartWithManyWorkers_HandedOnAndReadAgain', () => {
  const plan = planned('job.start', { job: 'next', host: 'claude', workers: '2' });
  assert.deepEqual([plan.outcome, plan.refreshAgainMs], ['started', HANDED_ON_REFRESH_MS], 'because next.sh starts its workers detached and exits, so they only show a few seconds later');
});

test('JobStartWithoutWorkers_ConfiguredWorkerPlan_HandedOn', () => {
  const plan = planned('job.start', { job: 'next', host: 'claude' }, { ...CONTEXT, jobsWorkers: true });
  assert.deepEqual([plan.outcome, plan.refreshAgainMs], ['started', HANDED_ON_REFRESH_MS], 'because next.sh on the queue follows jobs.workers when no --workers is given');
  const single = planned('job.start', { job: 'next', host: 'claude', workers: '1' }, { ...CONTEXT, jobsWorkers: true });
  assert.deepEqual([single.outcome, single.refreshAgainMs], ['finished', null], 'because --workers 1 overrides the plan with one session');
});

test('JobStartWithoutAJob_TheNextJob', () => {
  assert.deepEqual(planned('job.start', { host: 'codex' }).args, ['/p/app/.flow/jobs/next.sh', 'codex'], 'because next is the job most runs start, so naming it is optional');
});

test('JobStart_OtherJob_RunsItsOwnScriptWithModelAndEffort', () => {
  const plan = planned('job.start', { job: 'intake', host: 'codex', model: 'gpt-6-luna', effort: 'low' });
  assert.deepEqual(plan.args, ['/p/app/.flow/jobs/intake.sh', 'codex', '--model', 'gpt-6-luna', '--effort', 'low'], 'because every job takes the host first and its own model and effort');
  assert.deepEqual([plan.locks, plan.outcome], [['job:intake'], 'finished'], 'because the run takes that job\'s lock and ends in place');
});

test('JobStart_OtherJobWithNextOptions_Rejected', () => {
  for (const key of ['item', 'workers', 'maxSteps']) {
    const result = planAction('job.start', { job: 'health', host: 'claude', [key]: key === 'item' ? 'gh#1' : '2' }, CONTEXT);
    assert.match(result.ok ? '' : result.error, /is for the next job/, `because only next.sh takes ${key}`);
  }
});

test('JobStart_UnknownJob_Rejected', () => {
  for (const job of ['', 'next-2', 'deploy']) {
    assert.equal(planAction('job.start', { job, host: 'claude' }, CONTEXT).ok, false, `because "${job}" is not a job flow runs`);
  }
});

test('JobStart_BadArguments_Rejected', () => {
  const next = { job: 'next', host: 'claude' };
  const cases: [Record<string, string>, string][] = [
    [{ job: 'next' }, 'no host'], [{}, 'no host, the job left out'], [{ job: 'next', host: 'gemini' }, 'a host flow does not run'],
    [{ ...next, item: 'gh#1 x' }, 'an item id with a space'], [{ ...next, item: '-x' }, 'an item that reads as a flag'],
    [{ ...next, workers: '0' }, 'zero workers'], [{ ...next, workers: '100' }, 'a hundred workers'], [{ ...next, workers: '2x' }, 'workers not a number'],
    [{ ...next, maxSteps: '0' }, 'zero steps'], [{ ...next, maxSteps: '1000' }, 'four-digit steps'],
    [{ ...next, model: '-x' }, 'a model that reads as a flag'], [{ ...next, model: 'a b' }, 'a model with a space'], [{ ...next, model: '' }, 'an empty model'],
    [{ ...next, effort: 'huge' }, 'an effort no host has'], [{ job: 'next', host: 'codex', effort: 'max' }, 'max, which codex does not take'],
    [{ ...next, Workers: '2' }, 'a stray key'],
  ];
  for (const [args, what] of cases) assert.equal(planAction('job.start', args, CONTEXT).ok, false, `because ${what} is not a run next.sh can start`);
});

test('JobStartWithAnItemAndManyWorkers_RefusedWithTheReason', () => {
  const result = planAction('job.start', { job: 'next', host: 'claude', item: 'gh#12', workers: '2' }, CONTEXT);
  assert.match(result.ok ? '' : result.error, /workers run the queue/, 'because next.sh dies on --workers with an item, so the owner hears why before it runs');
  assert.equal(planAction('job.start', { job: 'next', host: 'claude', item: 'gh#12', workers: '1' }, CONTEXT).ok, true, 'because one worker on one item is one session');
});

test('JobStart_NextJobPaused_RefusedWithTheReason', () => {
  const result = planAction('job.start', { job: 'next', host: 'claude' }, { ...CONTEXT, nextJob: { paused: true, running: false } });
  assert.match(result.ok ? '' : result.error, /paused/, 'because next.sh exits quietly on a paused job, which would look like a run that did nothing');
});

/** The context with a config writer that records the keys it was asked to write and answers as the editor does. */
function writing(context: ActionContext = CONTEXT): { context: ActionContext; written: [string, string | null][] } {
  const written: [string, string | null][] = [];
  return { context: { ...context, writeConfig: async (key, value) => { written.push([key, value]); return `wrote ${key}\n`; } }, written };
}
const scheduleError = (args: Record<string, string>, context: ActionContext = writing().context): string => { const result = planAction('job.schedule', args, context); return result.ok ? '' : result.error; };

test('JobSchedule_NamedScheduleWithAnItem_WritesTheKeyThenInstallsThatSchedule', async () => {
  const { context, written } = writing();
  const plan = planned('job.schedule', { job: 'next-nightly', schedule: ' daily 02:00  gh#12 --max-steps 5 ' }, context);
  assert.deepEqual(plan.args, ['/plugins/flow/1.17.0/scripts/jobs.sh', 'install', 'next-nightly'], 'because jobs.sh install loads the one schedule named');
  assert.deepEqual([plan.locks, plan.refresh, plan.outcome], [['job:next-nightly'], ['jobs', 'files'], 'finished'], 'because one schedule takes one action at a time, and both the file and launchd changed');
  assert.equal(written.length, 0, 'because planning writes nothing; the file changes once the lock is held');
  const prepared = await plan.prepare?.();
  assert.deepEqual(written, [['jobs.schedule.next-nightly', 'daily 02:00 gh#12 --max-steps 5']], 'because the schedule goes to .flow/config.yaml first, its words as jobs.sh reads them, the item id among its args');
  assert.equal(prepared?.output, 'console: wrote jobs.schedule.next-nightly\n', 'because the action says what it wrote before install runs');
  assert.equal(plan.note?.('next-nightly: running now, left as it is; install it again after the run\n'), 'skipped next-nightly: running now, so it keeps the old schedule; install again after the run', 'because install still exits 0 when the schedule ran meanwhile');
});

test('JobSchedule_AJobsOwnName_Accepted', () => {
  const plan = planned('job.schedule', { job: 'health', schedule: 'every 15m' }, writing().context);
  assert.deepEqual(plan.args.slice(1), ['install', 'health'], 'because a job is the schedule of its own name');
});

test('JobSchedule_BadName_Refused', () => {
  for (const job of ['', 'nightly', 'next-Nightly', 'next-2', 'next-', 'deploy-nightly', 'next-nightly-extra', 'all', '../next']) {
    assert.match(scheduleError({ job, schedule: 'every 30m' }), /schedule name/, `because "${job}" is neither a job nor <job>-<label> with a label opening with a letter`);
  }
});

test('JobSchedule_BadSpec_RefusedAsJobsShWould', () => {
  for (const schedule of ['', 'hourly', 'daily 2:00', 'daily 24:00', 'every 0m', 'weekly someday 07:00', 'every 10m $(rm -rf ~)', "every 10m 'quoted'", 'every 10m a;b']) {
    assert.notEqual(scheduleError({ job: 'next-nightly', schedule }), '', `because _jobs.py refuses "${schedule}", and the file would hold a schedule install cannot load`);
  }
  assert.match(scheduleError({ job: 'next-nightly', schedule: 'every 10m #12' }), /comment/, 'because .flow/config.yaml reads " #" as the start of a comment');
  assert.equal(scheduleError({ job: 'next-nightly', schedule: 'every 30m local:task/5 --model=opus' }), '', 'because a local item id and an option with = are plain args');
});

test('JobSchedule_ScheduleRunning_Refused', () => {
  const { context } = writing({ ...CONTEXT, schedules: [{ name: 'next-nightly', running: true }, { name: 'health', running: false }] });
  assert.match(scheduleError({ job: 'next-nightly', schedule: 'every 30m' }, context), /running now/, 'because install leaves a running job as it is, so the new schedule would not load');
  assert.equal(scheduleError({ job: 'health', schedule: 'every 30m' }, context), '', 'because another schedule running is no reason to wait');
});

test('JobSchedule_WorkersBesideJobsWorkers_Refused', () => {
  const { context } = writing({ ...CONTEXT, jobsWorkers: true });
  assert.match(scheduleError({ job: 'next', schedule: 'every 30m --workers 3' }, context), /jobs\.workers/, 'because install refuses the next schedule that sets --workers beside jobs.workers, after the file was written');
  assert.equal(scheduleError({ job: 'next-wide', schedule: 'every 30m --workers 3' }, context), '', 'because a named next schedule runs its own --workers and never reads jobs.workers');
  assert.equal(scheduleError({ job: 'comments-fast', schedule: 'every 5m --workers 3' }, context), '', 'because only next reads jobs.workers');
});

test('JobSchedule_NoConfigEditor_Refused', () => {
  assert.match(scheduleError({ job: 'next-nightly', schedule: 'every 30m' }, CONTEXT), /cannot edit/, 'because the schedule must go through the config editor, never a write of its own');
});

test('JobUnschedule_UninstallsThenTakesTheKeyOut', async () => {
  const { context, written } = writing();
  const plan = planned('job.unschedule', { job: 'next-nightly' }, context);
  assert.deepEqual([plan.args.slice(1), plan.locks, plan.refresh], [['uninstall', 'next-nightly'], ['job:next-nightly'], ['jobs', 'files']], 'because launchd lets go of the schedule first');
  assert.equal(plan.prepare, undefined, 'because the file is left as it is until the uninstall worked');
  const concluded = await plan.conclude?.();
  assert.deepEqual(written, [['jobs.schedule.next-nightly', null]], 'because once unloaded, the key comes out of .flow/config.yaml; a key already gone is fine for an orphan');
  assert.equal(concluded?.output, 'console: wrote jobs.schedule.next-nightly\n', 'because the action says what changed in the file');
});

test('JobUnschedule_RunningOrBadName_Refused', () => {
  const { context } = writing({ ...CONTEXT, schedules: [{ name: 'next-nightly', running: true }] });
  assert.equal(planAction('job.unschedule', { job: 'next-nightly' }, context).ok, false, 'because unloading a running schedule would cut its run off');
  assert.equal(planAction('job.unschedule', { job: 'next-2' }, writing().context).ok, false, 'because next-2 is a worker, not a schedule');
  assert.equal(planAction('job.unschedule', { job: 'next-nightly', schedule: 'every 30m' }, writing().context).ok, false, 'because unschedule takes the name only');
});

test('JobUninstallAndRun_NamedSchedule_Accepted', () => {
  assert.deepEqual(planned('job.uninstall', { job: 'next-nightly' }).args.slice(1), ['uninstall', 'next-nightly'], 'because an orphaned named schedule is unloaded on its own too');
  assert.deepEqual(planned('job.stop', { job: 'next-nightly' }).args.slice(1), ['stop', 'next-nightly'], 'because every jobs.sh command takes a schedule name');
  assert.deepEqual(planned('job.pause', { job: 'all' }).args.slice(1), ['pause', 'all'], 'because jobs.sh pauses every schedule at once');
  assert.equal(planAction('job.run', { job: 'all' }, CONTEXT).ok, false, 'because jobs.sh runs one schedule at a time');
});

test('JobsInstall_NamedSchedulesListed_HoldsTheirLocksToo', () => {
  const plan = planned('jobs.install', {}, { ...CONTEXT, schedules: [{ name: 'next', running: false }, { name: 'next-nightly', running: false }] });
  assert.deepEqual(plan.locks, ['job:next', 'job:comments', 'job:intake', 'job:retro', 'job:health', 'job:next-nightly'], 'because install rewrites every schedule the config names');
});

test('RunStopAndResume_RunStewardWithTheItem', () => {
  const context = { ...CONTEXT, runItems: ['gh#7'] };
  const stop = planned('run.stop', { item: 'gh#7' }, context);
  assert.deepEqual([stop.args, stop.locks, stop.refresh, stop.outcome, stop.refreshAgainMs], [['/plugins/flow/1.17.0/scripts/steward.sh', 'stop', 'gh#7'], ['stop:item:gh#7'], ['files', 'processes'], 'finished', null], 'because steward.sh stop ends the run and removes its record, keeping the claim, and must reach a run that holds the item lock');
  const resume = planned('run.resume', { item: 'gh#7' }, context);
  assert.deepEqual([resume.args.slice(1), resume.locks, resume.outcome, resume.refreshAgainMs], [['resume', 'gh#7'], ['item:gh#7'], 'started', HANDED_ON_REFRESH_MS], 'because resume starts the step in the background, whose session shows a moment later');
});

test('RunStopAndResume_BadItemOrNoRunRecord_Refused', () => {
  for (const kind of ['run.stop', 'run.resume'] as const) {
    assert.equal(planAction(kind, { item: 'gh#7; rm' }, { ...CONTEXT, runItems: ['gh#7'] }).ok, false, `because ${kind} takes an item id only`);
    assert.match(refusal(planAction(kind, { item: 'gh#7' }, CONTEXT)), /no run record/, `because ${kind} acts on a run record, and none names gh#7`);
  }
  assert.ok(['job.schedule', 'job.unschedule', 'run.stop', 'run.resume'].every((kind) => (ACTION_KINDS as string[]).includes(kind)), 'because the server refuses a kind the list does not hold');
});
