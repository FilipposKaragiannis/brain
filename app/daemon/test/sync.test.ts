import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { SYNC_SCRIPT } from '../src/actionPlan.ts';

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
  } finally { cleanup(); }
});
