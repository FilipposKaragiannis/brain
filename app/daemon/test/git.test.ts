import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseWorktreeList } from '../src/collectors/git.ts';

test('WorktreeList_BranchAndDetached', () => {
  const entries = parseWorktreeList('worktree /w/main\nHEAD aaa\nbranch refs/heads/main\n\nworktree /w/free\nHEAD bbb\ndetached\n');
  assert.deepEqual(entries, [
    { path: '/w/main', head: 'aaa', branch: 'main' },
    { path: '/w/free', head: 'bbb', branch: null },
  ], 'because a free worktree sits detached at the base');
});
