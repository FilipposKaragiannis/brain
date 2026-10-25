import path from 'node:path';
import type { ActionKind, ActionOutcome } from './snapshot.ts';
import { SOURCE_NAMES } from './snapshot.ts';

/** What an action needs from the project before it can be planned. */
export type ActionContext = {
  root: string;
  pluginRoot: string | null;
  repo: string | null;
  jobsHost: string;
  /** The pool worktrees, as absolute paths. A release names one of these or an item. */
  pool: string[];
};

/** One planned process. `detach` puts it in its own session so it outlives the daemon. */
export type ActionPlan = {
  command: string;
  args: string[];
  cwd: string;
  locks: string[];
  timeoutMs: number;
  detach: boolean;
  /** Sources to re-read once the process ends. */
  refresh: string[];
  /**
   * Re-read the `refresh` sources once more this long after the process ends, for a script that
   * hands its work on and returns before the work shows; null when once is enough.
   */
  refreshAgainMs: number | null;
  /** What a clean exit means: the work is over (`finished`) or was handed on and goes on (`started`). */
  outcome: ActionOutcome;
};

export type PlanResult = { ok: true; plan: ActionPlan } | { ok: false; error: string };

export const ACTION_KINDS: ActionKind[] = [
  'gate.clear', 'run.start', 'job.run', 'job.stop', 'job.pause', 'job.resume',
  'worktree.claim', 'worktree.release', 'steward.health', 'pr.merge', 'refresh',
];

/** The argument names each kind accepts. Anything else is refused, so a typo never changes the meaning. */
const ARGUMENTS: Record<ActionKind, string[]> = {
  'gate.clear': ['item', 'message'],
  'run.start': ['item', 'maxSteps'],
  'job.run': ['job'], 'job.stop': ['job'], 'job.pause': ['job'], 'job.resume': ['job'],
  'worktree.claim': ['item'],
  'worktree.release': ['target', 'force'],
  'steward.health': [],
  'pr.merge': ['pr', 'method'],
  refresh: ['source'],
};

const SECOND_MS = 1000;
export const SCRIPT_TIMEOUT_MS = 120 * SECOND_MS;
const STEWARD_TIMEOUT_MS = 600 * SECOND_MS;
const MERGE_TIMEOUT_MS = 180 * SECOND_MS;
/**
 * `jobs.sh run <job>` hands the job to launchd and returns in a second; the job's own run shows
 * in `jobs.sh status` a few seconds later, so its sources are read again after this.
 */
export const HANDED_ON_REFRESH_MS = 5 * SECOND_MS;
/** The step budget of a run started from the console, the next job's own default. */
const DEFAULT_MAX_STEPS = 15;
const MESSAGE_LIMIT_CHARS = 10000;
/** The ids the adapters own: gh#12 on GitHub, local:task/7 in the local tracker. Nothing else reaches a script. */
const ITEM_ID = /^(gh#[1-9][0-9]*|local:[a-z]+\/[1-9][0-9]*)$/;
const JOB_NAME = /^[a-z][a-z0-9-]*$/;
const PR_NUMBER = /^[1-9][0-9]*$/;
const MAX_STEPS = /^[1-9][0-9]{0,2}$/;
const MERGE_METHODS = ['squash', 'merge', 'rebase'];

const fail = (error: string): PlanResult => ({ ok: false, error });

function script(context: ActionContext, name: string): string {
  return path.join(context.pluginRoot ?? '', 'scripts', name);
}

/** A release target: an item id, passed as is, or the name of a pool worktree, passed as its path. */
function releaseTarget(target: string, context: ActionContext): string | null {
  if (ITEM_ID.test(target)) return target;
  return context.pool.find((worktree) => path.basename(worktree) === target) ?? null;
}

/**
 * Turns a kind and its arguments into one exact process, or says why not. Pure: nothing runs
 * here. Every argument is checked against a shape before it reaches a script, and every script
 * is called by path with argv, never through a shell.
 */
export function planAction(kind: ActionKind, args: Record<string, string>, context: ActionContext): PlanResult {
  const unknown = Object.keys(args).find((key) => !ARGUMENTS[kind].includes(key));
  if (unknown !== undefined) return fail(`${kind} does not take ${unknown}`);
  if (kind === 'refresh') {
    const source = args['source'] ?? '';
    if (source !== '' && !(SOURCE_NAMES as string[]).includes(source)) return fail(`unknown source: ${source}`);
    return { ok: true, plan: { command: '', args: [], cwd: context.root, locks: [], timeoutMs: 0, detach: false, refresh: source === '' ? [...SOURCE_NAMES] : [source], refreshAgainMs: null, outcome: 'finished' } };
  }
  if (context.pluginRoot === null) return fail('no flow plugin found for the project');
  const sh = (name: string, scriptArgs: string[], locks: string[], timeoutMs: number, refresh: string[]): PlanResult =>
    ({ ok: true, plan: { command: 'sh', args: [script(context, name), ...scriptArgs], cwd: context.root, locks, timeoutMs, detach: false, refresh, refreshAgainMs: null, outcome: 'finished' } });
  /** `jobs.sh run <job>`: launchd runs the job, the script only starts it. */
  const handOn = (job: string, locks: string[], refresh: string[]): PlanResult => {
    const planned = sh('jobs.sh', ['run', job], locks, SCRIPT_TIMEOUT_MS, refresh);
    return planned.ok ? { ok: true, plan: { ...planned.plan, refreshAgainMs: HANDED_ON_REFRESH_MS, outcome: 'started' } } : planned;
  };
  switch (kind) {
    case 'gate.clear': {
      const item = args['item'] ?? '';
      const message = args['message'] ?? '';
      if (!ITEM_ID.test(item)) return fail('gate.clear needs an item id like gh#12 or local:task/7');
      if (message.length > MESSAGE_LIMIT_CHARS) return fail(`message longer than ${MESSAGE_LIMIT_CHARS} characters`);
      return sh('gate.sh', message === '' ? ['clear', item] : ['clear', item, message], [`item:${item}`], SCRIPT_TIMEOUT_MS, ['files', 'board']);
    }
    case 'run.start': {
      const item = args['item'] ?? '';
      const maxSteps = args['maxSteps'] ?? String(DEFAULT_MAX_STEPS);
      if (item !== '' && !ITEM_ID.test(item)) return fail('run.start takes an item id or nothing');
      if (!MAX_STEPS.test(maxSteps)) return fail('maxSteps must be a number from 1 to 999');
      if (item === '') {
        if (args['maxSteps'] !== undefined) return fail('maxSteps needs an item; the scheduled next job has its own');
        return handOn('next', ['job:next'], ['jobs', 'processes']);
      }
      // jobs/next.sh with an item takes the next job's own lock, so the console mirrors it: a
      // scheduled next run and a console run never both believe they hold the queue.
      const job = path.join(context.pluginRoot, 'jobs', 'next.sh');
      return { ok: true, plan: { command: 'sh', args: [job, context.jobsHost, item, '--max-steps', maxSteps], cwd: context.root, locks: [`item:${item}`, 'job:next'], timeoutMs: 0, detach: true, refresh: ['files', 'processes', 'board'], refreshAgainMs: null, outcome: 'finished' } };
    }
    case 'job.run': case 'job.stop': case 'job.pause': case 'job.resume': {
      const job = args['job'] ?? '';
      if (!JOB_NAME.test(job)) return fail(`${kind} needs a job name`);
      if (kind === 'job.run') return handOn(job, [`job:${job}`], ['jobs', 'processes']);
      return sh('jobs.sh', [kind.slice('job.'.length), job], [`job:${job}`], SCRIPT_TIMEOUT_MS, ['jobs', 'processes']);
    }
    case 'worktree.claim': {
      const item = args['item'] ?? '';
      if (!ITEM_ID.test(item)) return fail('worktree.claim needs an item id');
      return sh('steward.sh', ['claim', item], ['pool', `item:${item}`], STEWARD_TIMEOUT_MS, ['files', 'git']);
    }
    case 'worktree.release': {
      const target = releaseTarget(args['target'] ?? '', context);
      if (target === null) return fail('worktree.release needs an item id or the name of a pool worktree');
      const force = args['force'] === 'true' ? ['--force'] : [];
      return sh('steward.sh', ['release', target, ...force], ['pool', `${ITEM_ID.test(target) ? 'item' : 'worktree'}:${target}`], STEWARD_TIMEOUT_MS, ['files', 'git']);
    }
    case 'steward.health': return handOn('health', ['job:health'], ['jobs', 'files', 'git']);
    case 'pr.merge': {
      const pr = args['pr'] ?? '';
      const method = args['method'] ?? 'squash';
      if (!PR_NUMBER.test(pr)) return fail('pr.merge needs a PR number');
      if (!MERGE_METHODS.includes(method)) return fail(`method must be one of ${MERGE_METHODS.join(', ')}`);
      if (context.repo === null) return fail('pr.merge needs github.repo in .flow/config.yaml');
      return { ok: true, plan: { command: 'gh', args: ['pr', 'merge', pr, '--repo', context.repo, `--${method}`, '--delete-branch'], cwd: context.root, locks: [`pr:${pr}`], timeoutMs: MERGE_TIMEOUT_MS, detach: false, refresh: ['board', 'git', 'pulls'], refreshAgainMs: null, outcome: 'finished' } };
    }
  }
}
