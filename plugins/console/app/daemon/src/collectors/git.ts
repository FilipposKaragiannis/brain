import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

export type GitWorktree = {
  path: string;
  head: string;
  branch: string | null;
  aheadOfBase: number | null;
  behindBase: number | null;
  dirtyFiles: number | null;
  lastCommitAt: string | null;
};

export type GitFacts = { worktrees: GitWorktree[] };

const GIT_TIMEOUT_MS = 15000;
const PARALLEL_WORKTREES = 4;

type ListedWorktree = { path: string; head: string; branch: string | null };

/** `git worktree list --porcelain` into entries. A detached worktree has no branch. */
export function parseWorktreeList(source: string): ListedWorktree[] {
  const entries: ListedWorktree[] = [];
  let current: ListedWorktree | null = null;
  for (const line of source.split('\n')) {
    if (line.startsWith('worktree ')) { current = { path: line.slice('worktree '.length), head: '', branch: null }; entries.push(current); continue; }
    if (current === null) continue;
    if (line.startsWith('HEAD ')) current.head = line.slice('HEAD '.length);
    if (line.startsWith('branch refs/heads/')) current.branch = line.slice('branch refs/heads/'.length);
  }
  return entries;
}

async function git(runner: CommandRunner, cwd: string, args: string[]): Promise<string | null> {
  const result = await runner({ command: 'git', args, cwd, timeoutMs: GIT_TIMEOUT_MS, env: scriptEnvironment() });
  return result.code === 0 ? result.stdout : null;
}

async function describe(runner: CommandRunner, base: string, listed: ListedWorktree): Promise<GitWorktree> {
  const counts = await git(runner, listed.path, ['rev-list', '--left-right', '--count', `${base}...HEAD`]);
  const status = await git(runner, listed.path, ['status', '--porcelain', '--untracked-files=normal']);
  const lastCommit = await git(runner, listed.path, ['log', '-1', '--format=%cI']);
  const [behind, ahead] = counts === null ? [null, null] : counts.trim().split(/\s+/).map(Number);
  return {
    ...listed,
    aheadOfBase: ahead ?? null,
    behindBase: behind ?? null,
    dirtyFiles: status === null ? null : status.split('\n').filter((line) => line.length > 0).length,
    lastCommitAt: lastCommit === null ? null : lastCommit.trim() || null,
  };
}

export async function readGit(root: string, base: string, runner: CommandRunner): Promise<GitFacts> {
  const listing = await git(runner, root, ['worktree', 'list', '--porcelain']);
  if (listing === null) return { worktrees: [] };
  const listed = parseWorktreeList(listing);
  const worktrees: GitWorktree[] = [];
  for (let index = 0; index < listed.length; index += PARALLEL_WORKTREES) {
    const batch = listed.slice(index, index + PARALLEL_WORKTREES);
    worktrees.push(...(await Promise.all(batch.map((entry) => describe(runner, base, entry)))));
  }
  return { worktrees };
}
