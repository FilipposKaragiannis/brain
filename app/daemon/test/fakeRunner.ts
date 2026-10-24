import path from 'node:path';
import type { CommandRequest, CommandResult, CommandRunner } from '../src/collectors/exec.ts';

export const FIXTURES = path.resolve(import.meta.dirname, 'fixtures');
export const FIXTURE_ROOT = path.join(FIXTURES, 'project');
export const FAKE_PLUGIN = '/fake/plugins/flow/9.9.9';

const ok = (stdout: string): CommandResult => ({ code: 0, stdout, stderr: '', timedOut: false });

const WORKTREE_LIST = [
  `worktree ${FIXTURE_ROOT}\nHEAD 1111111\nbranch refs/heads/main\n`,
  `worktree ${FIXTURES}/project-wt-2\nHEAD 2222222\nbranch refs/heads/flow/gh-7\n`,
  `worktree ${FIXTURES}/project-wt-3\nHEAD 3333333\nbranch refs/heads/flow/gh-9\n`,
  `worktree ${FIXTURES}/project-wt-4\nHEAD 4444444\nbranch refs/heads/flow/gh-5\n`,
  `worktree ${FIXTURES}/project-side\nHEAD 5555555\ndetached\n`,
].join('\n');

const PROCESSES = [
  `  100   15:42 /usr/local/bin/claude -p /flow:next gh#9 --permission-mode auto`,
  `  104   02:00 /usr/local/bin/claude --session-id abc --permission-mode auto`,
  `  101 01-02:03:04 /Users/x/.local/bin/claude daemon run --origin transient`,
  `  102   00:09 /opt/codex app-server --listen unix://`,
  `  103   03:00 /opt/codex exec --cd somewhere`,
].join('\n');

const CWDS = `p100\nfcwd\nn${FIXTURES}/project-wt-3\np103\nfcwd\nn/elsewhere\np104\nfcwd\nn${FIXTURES}/project-wt-2/src\n`;

export const JOBS_JSON = JSON.stringify([
  { job: 'next', schedule: 'every 30m', args: '--workers 2', installed: true, paused: false, loaded: true, running: [], week: { work: 1, failed: 0 }, last: { at: '2026-10-24T17:44:00Z', seconds: 107, exit: 0, result: 'quiet', outcome: 'quiet' }, next: 'due' },
  { job: 'health', schedule: 'every 15m', args: '', installed: true, paused: false, loaded: true, running: [{ job: 'health', at: '2026-10-24T18:13:00Z' }], week: { quiet: 4, failed: 1 }, last: { at: '2026-10-24T17:58:00Z', seconds: 16, exit: 1, result: 'git failed', outcome: 'failed' }, next: '18:28' },
  { job: 'retro', schedule: 'weekly sun 07:00', args: '', installed: true, paused: true, loaded: true, running: [], week: {}, last: null, next: 'Oct 26 07:00' },
]);

export const BOARD_JSON = JSON.stringify({
  items: [
    { id: 'gh#7', kind: 'task', title: 'Seven', size: 'M', priority: 'P1', rank: 1, needs: [], status: 'open', labels: [], blocked_by: [], open_blockers: [], open_children: 0, parent: '', url: 'https://example/7', body: 'long body', state: { step: 'implement', gate: 'none', worktree: 'project-wt-2', pr: '', last_event: '', profile: '', attempts: 0 } },
    { id: 'gh#9', kind: 'bug', title: 'Nine', size: 'S', priority: 'P0', rank: 2, needs: [], status: 'open', labels: [], blocked_by: [], open_blockers: [], open_children: 0, parent: '', url: 'https://example/9', body: '', state: { step: 'implement', gate: 'none', worktree: 'project-wt-3', pr: '', last_event: '', profile: '', attempts: 0 } },
    { id: 'gh#12', kind: 'task', title: 'Twelve', size: 'S', priority: 'P2', rank: 3, needs: [], status: 'open', labels: [], blocked_by: [], open_blockers: [], open_children: 0, parent: '', url: 'https://example/12', body: '', state: { step: '', gate: 'none', worktree: '', pr: '', last_event: '', profile: '', attempts: 0 } },
    { id: 'gh#13', kind: 'task', title: 'Thirteen', size: '', priority: '', rank: 999, needs: ['size'], status: 'open', labels: [], blocked_by: ['gh#12'], open_blockers: ['gh#12'], open_children: 0, parent: '', url: 'https://example/13', body: '', state: { step: '', gate: 'none', worktree: '', pr: '', last_event: '', profile: '', attempts: 0 } },
    { id: 'gh#2', kind: 'task', title: 'Two', size: 'S', priority: 'P1', rank: 999, needs: [], status: 'closed', labels: [], blocked_by: [], open_blockers: [], open_children: 0, parent: '', url: 'https://example/2', body: '', state: { step: 'done', gate: 'none', worktree: '', pr: 'https://example/pull/2', last_event: '', profile: '', attempts: 0 } },
    { id: 'gh#20', kind: 'task', title: 'Twenty', size: 'S', priority: 'P1', rank: 4, needs: [], status: 'open', labels: [], blocked_by: [], open_blockers: [], open_children: 0, parent: '', url: 'https://example/20', body: '', state: { step: 'done', gate: 'none', worktree: '', pr: 'https://example/pull/20', last_event: '', profile: '', attempts: 0 } },
  ],
});

/** Answers every command the collectors run against the fixture project, without a shell. */
export const fakeRunner: CommandRunner = async (request: CommandRequest): Promise<CommandResult> => {
  const [first, second] = request.args;
  if (request.command === 'sh' && first === '-c') return ok(FAKE_PLUGIN);
  if (request.command === 'sh' && first?.endsWith('jobs.sh')) return ok(JOBS_JSON);
  if (request.command === 'sh' && first?.endsWith('board.sh')) return ok(BOARD_JSON);
  if (request.command === 'git' && first === 'worktree') return ok(WORKTREE_LIST);
  if (request.command === 'git' && first === 'rev-list') return ok(request.cwd.endsWith('project-wt-4') ? '35\t4\n' : '0\t2\n');
  if (request.command === 'git' && first === 'status') return ok(request.cwd.endsWith('project-wt-3') ? ' M a.cs\n?? b.cs\n' : '');
  if (request.command === 'git' && first === 'log') return ok('2026-10-24T18:10:00+01:00\n');
  if (request.command === 'ps') return ok(PROCESSES);
  if (request.command === 'lsof') return ok(CWDS);
  return { code: 1, stdout: '', stderr: `fake runner: unknown command ${request.command} ${first ?? ''} ${second ?? ''}`, timedOut: false };
};
