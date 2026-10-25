import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { SYNC_SCRIPT } from '../src/actionPlan.ts';
import type { ActionContext } from '../src/actionPlan.ts';
import { ActionRunner, childProcessSpawner, realScheduler } from '../src/actions.ts';
import type { Logger } from '../src/log.ts';
import { silentLogger } from '../src/log.ts';
import type { ActionRecord } from '../src/snapshot.ts';
import { syncConflict, syncNotePath, syncRefs } from '../src/syncNote.ts';
import { fakeSpawner, settle, until } from './fakeSpawner.ts';

/**
 * The sync script against real git in a temporary folder: a remote, a main checkout that pushes
 * to it, and a worktree whose branch tracks its own pushed copy. No project is touched.
 */
function repos() {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-sync-'));
  const git = (cwd: string, ...args: string[]): string => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'init.defaultBranch=main', '-c', 'core.hooksPath=/dev/null', ...args], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const remote = path.join(dir, 'remote.git');
  const main = path.join(dir, 'main');
  const worktree = path.join(dir, 'wt');
  git(dir, 'init', '-q', '--bare', remote);
  git(dir, 'clone', '-q', remote, main);
  const commit = (cwd: string, file: string, text: string): void => { writeFileSync(path.join(cwd, file), text); git(cwd, 'add', file); git(cwd, 'commit', '-q', '-m', `${file}: ${text}`); };
  commit(main, 'a.txt', 'one\n');
  git(main, 'push', '-q', 'origin', 'HEAD:main');
  git(main, 'worktree', 'add', '-q', '-b', 'flow/gh-7', worktree);
  git(worktree, 'push', '-q', '-u', 'origin', 'flow/gh-7');
  const sync = () => spawnSync('sh', [SYNC_SCRIPT, worktree, 'main'], { encoding: 'utf8', env: { ...process.env, GIT_CONFIG_COUNT: '2', GIT_CONFIG_KEY_0: 'user.name', GIT_CONFIG_VALUE_0: 't', GIT_CONFIG_KEY_1: 'user.email', GIT_CONFIG_VALUE_1: 't@t' } });
  return { dir, git, main, worktree, commit, sync, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('Sync_BaseAheadOnTheRemote_MergesOriginBase', () => {
  const { git, main, worktree, commit, sync, cleanup } = repos();
  try {
    commit(main, 'b.txt', 'two\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    const run = sync();
    assert.equal(run.status, 0, `because a clean merge succeeds: ${run.stdout}${run.stderr}`);
    assert.match(run.stdout, /merged origin\/main/, 'because the output names what was merged');
    assert.equal(git(worktree, 'rev-list', '--count', 'HEAD..origin/main').trim(), '0', 'because the branch now has every commit of the remote base');
  } finally { cleanup(); }
});

test('Sync_UpstreamAhead_MergedBeforeTheBase', () => {
  const { dir, git, main, worktree, commit, sync, cleanup } = repos();
  try {
    const other = path.join(dir, 'other');
    git(dir, 'clone', '-q', '-b', 'flow/gh-7', path.join(dir, 'remote.git'), other);
    commit(other, 'c.txt', 'from elsewhere\n');
    git(other, 'push', '-q', 'origin', 'flow/gh-7');
    commit(main, 'b.txt', 'two\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    const run = sync();
    assert.equal(run.status, 0, `because both merges are clean: ${run.stdout}${run.stderr}`);
    assert.ok(run.stdout.indexOf('merged origin/flow/gh-7') < run.stdout.indexOf('merged origin/main') && run.stdout.includes('merged origin/flow/gh-7'), 'because the branch takes its own pushed commits first, then the base');
  } finally { cleanup(); }
});

test('Sync_Conflict_AbortedAndTheFilesNamed', () => {
  const { git, main, worktree, commit, sync, cleanup } = repos();
  try {
    commit(main, 'a.txt', 'main says\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    commit(worktree, 'a.txt', 'branch says\n');
    const head = git(worktree, 'rev-parse', 'HEAD');
    const run = sync();
    assert.notEqual(run.status, 0, 'because a conflicting merge fails the action');
    assert.match(run.stdout, /conflicts, so the merge was aborted\. Conflicting files:\na\.txt/, 'because the owner needs to know which files to resolve by hand');
    assert.deepEqual([git(worktree, 'rev-parse', 'HEAD'), git(worktree, 'status', '--porcelain')], [head, ''], 'because an aborted merge leaves the worktree as it was');
    assert.deepEqual(syncConflict(run.stdout), { refs: ['origin/main'], files: ['a.txt'] }, 'because the record carries what to hand to the flow');
  } finally { cleanup(); }
});

test('Sync_UpstreamConflicts_EveryRefStillToMergeNamed', () => {
  const { dir, git, main, worktree, commit, sync, cleanup } = repos();
  try {
    const other = path.join(dir, 'other');
    git(dir, 'clone', '-q', '-b', 'flow/gh-7', path.join(dir, 'remote.git'), other);
    commit(other, 'a.txt', 'pushed from elsewhere\n');
    git(other, 'push', '-q', 'origin', 'flow/gh-7');
    commit(main, 'b.txt', 'two\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    commit(worktree, 'a.txt', 'branch says\n');
    const run = sync();
    assert.deepEqual(syncConflict(run.stdout), { refs: ['origin/flow/gh-7', 'origin/main'], files: ['a.txt'] }, 'because the base the script never reached still needs merging, after the upstream, as the health job orders a diverged branch');
  } finally { cleanup(); }
});

test('SyncRefs_TheRefsTheScriptWouldMerge_WithoutMerging', () => {
  const { dir, git, main, worktree, commit, cleanup } = repos();
  try {
    const other = path.join(dir, 'other');
    git(dir, 'clone', '-q', '-b', 'flow/gh-7', path.join(dir, 'remote.git'), other);
    commit(other, 'c.txt', 'from elsewhere\n');
    git(other, 'push', '-q', 'origin', 'flow/gh-7');
    commit(main, 'b.txt', 'two\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    git(worktree, 'fetch', '-q', 'origin');
    const head = git(worktree, 'rev-parse', 'HEAD');
    assert.deepEqual(syncRefs(SYNC_SCRIPT, worktree, 'main'), ['origin/flow/gh-7', 'origin/main'], 'because a hand-off with no conflict record merges what sync.sh would, in its order');
    assert.equal(git(worktree, 'rev-parse', 'HEAD'), head, 'because listing the refs merges nothing');
  } finally { cleanup(); }
});

/** An action runner over the temp repos: the worktree is pool slot wt, claimed for gh#7. */
async function runnerOver(worktree: string, dir: string, log: Logger, spawner = childProcessSpawner) {
  const context: ActionContext = {
    root: path.join(dir, 'main'), pluginRoot: path.join(dir, 'plugin'), repo: null, jobsHost: 'claude', pool: [worktree], outsideWorktrees: [], processCwds: [], sessions: [], terminal: null, installedTerminals: [], base: 'main',
    worktrees: [{ name: 'wt', path: worktree, item: 'gh#7', claimBase: null, dirtyFiles: 0, behindBase: 1, agentPids: [] }], runItems: [],
  };
  const events: ActionRecord[] = [];
  const actions = new ActionRunner({ projectId: 'p', context: () => context, spawner, scheduler: realScheduler, clock: () => new Date(), log, stateDir: path.join(dir, 'state'), onRefresh: () => {} });
  actions.onChange((record) => events.push(record));
  return { actions, events };
}

test('WorktreeSyncAction_RealConflict_RecordCarriesTheConflict', async () => {
  const { dir, git, main, worktree, commit, cleanup } = repos();
  try {
    commit(main, 'a.txt', 'main says\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    commit(worktree, 'a.txt', 'branch says\n');
    const { actions, events } = await runnerOver(worktree, dir, silentLogger);
    const started = actions.request('worktree.sync', { target: 'wt' });
    const id = (started.body as { action: ActionRecord }).action.id;
    await until(() => events.some((record) => record.id === id && record.state !== 'running'), 20000);
    const record = actions.get(id)!;
    assert.deepEqual([record.state, record.outcome, record.conflict], ['failed', null, { refs: ['origin/main'], files: ['a.txt'] }], 'because a conflicted sync failed, did nothing, and says what to hand to the flow');
    await actions.whenIdle();
  } finally { cleanup(); }
});

test('SyncHandoffAction_NoRefsGiven_WritesWhatSyncWouldMergeThenStartsTheRun', async () => {
  const { dir, git, main, worktree, commit, cleanup } = repos();
  try {
    commit(main, 'b.txt', 'two\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    git(worktree, 'fetch', '-q', 'origin');
    const logged: [string, Record<string, unknown>][] = [];
    const log: Logger = { ...silentLogger, info: (event, fields) => { logged.push([event, fields ?? {}]); } };
    const fake = fakeSpawner({ failWith: null, detachedOutput: '' });
    const { actions } = await runnerOver(worktree, dir, log, fake.spawner);
    const outcome = actions.request('sync.handoff', { target: 'gh#7' });
    assert.equal(outcome.status, 202, `because a branch behind its base with nothing running has a merge to hand on: ${JSON.stringify(outcome.body)}`);
    assert.equal(readFileSync(syncNotePath(worktree, 'gh#7'), 'utf8'), 'origin/main\n', 'because the note names what sync.sh would merge, one ref per line');
    assert.deepEqual(fake.processes[0]?.plan.args.slice(1), ['claude', 'gh#7', '--max-steps', '15'], "because the run starts as run.start starts the item's run");
    assert.match((outcome.body as { action: ActionRecord }).action.outputTail, /wrote .*sync\.md[\s\S]*its first step is sync/, 'because the output says what was written and what runs first');
    assert.deepEqual(logged.filter(([event]) => event === 'sync.handoff').map(([, fields]) => fields['refs']), [['origin/main']], 'because the hand-off is one log line with its refs');
    await settle();
    await actions.whenIdle();
  } finally { cleanup(); }
});

test('Sync_TermMidMerge_MergeAbortedAndNonZero', async () => {
  const { dir, git, main, worktree, commit, cleanup } = repos();
  try {
    commit(main, 'b.txt', 'two\n');
    git(main, 'push', '-q', 'origin', 'HEAD:main');
    commit(worktree, 'c.txt', 'branch\n');
    const head = git(worktree, 'rev-parse', 'HEAD');
    // A git that stops halfway through a merge: the merge is staged (MERGE_HEAD written), then it waits.
    const bin = path.join(dir, 'bin');
    const real = execFileSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).trim();
    execFileSync('mkdir', [bin]);
    writeFileSync(path.join(bin, 'git'), `#!/bin/sh\ncase " $* " in *" merge --no-edit "*) "${real}" -c user.name=t -c user.email=t@t "$@" --no-commit --no-ff; touch "${dir}/mid-merge"; exec sleep 30 ;; esac\nexec "${real}" "$@"\n`, { mode: 0o755 });
    const child = spawn('sh', [SYNC_SCRIPT, worktree, 'main'], { detached: true, env: { ...process.env, PATH: `${bin}:${process.env['PATH'] ?? ''}` }, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (chunk: Buffer) => { output += chunk.toString(); });
    while (!existsSync(path.join(dir, 'mid-merge'))) await new Promise((resolve) => setTimeout(resolve, 50));
    const ended = new Promise<number | null>((resolve) => child.on('close', (code) => resolve(code)));
    process.kill(-child.pid!, 'SIGTERM');
    const code = await ended;
    assert.notEqual(code, 0, 'because a sync cut short did not bring the branch up to date');
    assert.match(output, /stopped while merging origin\/main; the merge was aborted/, 'because the output says what was undone');
    const gitPath = (name: string): string => path.resolve(worktree, git(worktree, 'rev-parse', '--git-path', name).trim());
    assert.deepEqual([existsSync(gitPath('MERGE_HEAD')), existsSync(gitPath('index.lock')), git(worktree, 'rev-parse', 'HEAD'), git(worktree, 'status', '--porcelain')], [false, false, head, ''], 'because a timeout must not leave a half merge or a lock that blocks the next git command');
  } finally { cleanup(); }
});
