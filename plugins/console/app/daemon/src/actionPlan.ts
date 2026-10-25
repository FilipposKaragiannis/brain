import path from 'node:path';
import type { ActionKind, ActionOutcome, SessionRef, TerminalName, TerminalSetting } from './snapshot.ts';
import { SOURCE_NAMES } from './snapshot.ts';
import { sessionLaunch, terminalLaunch } from './terminal.ts';

/** What a sync needs to know of one pool worktree, from the latest snapshot. */
export type SyncFacts = {
  name: string;
  path: string;
  /** The claimed item, or null when nobody claimed it. */
  item: string | null;
  /** The base the claim was made from, or null to use the project's. */
  claimBase: string | null;
  /** Uncommitted files, or null before git was read. */
  dirtyFiles: number | null;
  /** The pids of the unattended agents working in it. */
  agentPids: number[];
};

/** A process's session as the snapshot lists it: where it ran, how to resume it, and whether the process still runs. */
export type SessionFacts = { pid: number; cwd: string; session: SessionRef; alive: boolean };

/** What an action needs from the project before it can be planned. */
export type ActionContext = {
  root: string;
  pluginRoot: string | null;
  repo: string | null;
  jobsHost: string;
  /** The pool worktrees, as absolute paths. A release names one of these or an item. */
  pool: string[];
  /** The worktrees outside the pool that git lists for the project (the main checkout among them); a terminal may open there. */
  outsideWorktrees: string[];
  /** The working directory of every agent and session the snapshot lists, so only those in this project's worktrees. */
  processCwds: string[];
  /** The sessions of the agents and sessions the snapshot lists (alive) and of those that ended since (not alive). */
  sessions: SessionFacts[];
  /** The terminal chosen in Settings, or null for the first installed one. */
  terminal: TerminalSetting | null;
  /** The terminals installed, first choice first. */
  installedTerminals: TerminalName[];
  /** The branch work merges into, `base` in .flow/config.yaml. */
  base: string;
  /** The pool worktrees as the latest snapshot shows them; empty before the first one. */
  worktrees: SyncFacts[];
  /** Every item a run record in .flow/runs names. */
  runItems: string[];
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
  /** Reads the output of a finished process for a note on its record (the jobs an install skipped); absent for most plans. */
  note?: (output: string) => string | null;
};

/**
 * `jobs.sh install` leaves a running job as it is ("next: running now, left as it is; install it
 * again after the run") and still exits 0, so the record says which jobs kept their old schedule.
 */
export function installNote(output: string): string | null {
  const skipped = [...output.matchAll(/^([a-z][a-z0-9-]*): running now, left as it is/gm)].map((match) => match[1]!);
  return skipped.length === 0 ? null : `skipped ${skipped.join(', ')}: running now, so ${skipped.length === 1 ? 'it keeps' : 'they keep'} the old schedule; install again after the run`;
}

export type PlanResult = { ok: true; plan: ActionPlan } | { ok: false; error: string };

export const ACTION_KINDS: ActionKind[] = [
  'gate.clear', 'run.start', 'job.run', 'job.stop', 'job.pause', 'job.resume',
  'worktree.claim', 'worktree.release', 'worktree.sync', 'steward.health', 'jobs.install', 'job.uninstall', 'pr.merge', 'terminal.open', 'refresh',
];

/** The argument names each kind accepts. Anything else is refused, so a typo never changes the meaning. */
const ARGUMENTS: Record<ActionKind, string[]> = {
  'gate.clear': ['item', 'message'],
  'run.start': ['item', 'maxSteps'],
  'job.run': ['job'], 'job.stop': ['job'], 'job.pause': ['job'], 'job.resume': ['job'],
  'worktree.claim': ['item'],
  'worktree.release': ['target', 'force'],
  'worktree.sync': ['target'],
  'steward.health': [],
  'jobs.install': [],
  'job.uninstall': ['job'],
  'pr.merge': ['pr', 'method'],
  'terminal.open': ['path', 'job', 'session'],
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
/** The jobs `jobs.sh` knows; an install rewrites the schedule of every one, so it holds all their locks. */
export const FLOW_JOBS = ['next', 'comments', 'intake', 'retro', 'health'];
const MESSAGE_LIMIT_CHARS = 10000;
/** The ids the adapters own: gh#12 on GitHub, local:task/7 in the local tracker. Nothing else reaches a script. */
const ITEM_ID = /^(gh#[1-9][0-9]*|local:[a-z]+\/[1-9][0-9]*)$/;
const JOB_NAME = /^[a-z][a-z0-9-]*$/;
const PR_NUMBER = /^[1-9][0-9]*$/;
const PID = /^[1-9][0-9]*$/;
const MAX_STEPS = /^[1-9][0-9]{0,2}$/;
const MERGE_METHODS = ['squash', 'merge', 'rebase'];
/** A branch name git takes without reading it as an option or a range. */
const BRANCH = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;
/** The console's own merge script: fetch, the upstream, then the base, aborting on a conflict. */
export const SYNC_SCRIPT = path.resolve(import.meta.dirname, '..', 'scripts', 'sync.sh');
/** How much of a job's log a terminal shows before it follows new lines. */
const LOG_LINES = '200';

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
  if (kind === 'terminal.open') return planTerminal(args, context);
  if (kind === 'worktree.sync') return planSync(args, context);
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
    // Writes and loads the schedule of every job jobs.schedule names: after a schedule or jobs.host change in .flow/config.yaml.
    case 'jobs.install': {
      const planned = sh('jobs.sh', ['install'], FLOW_JOBS.map((job) => `job:${job}`), SCRIPT_TIMEOUT_MS, ['jobs']);
      return planned.ok ? { ok: true, plan: { ...planned.plan, note: installNote } } : planned;
    }
    // A job whose schedule left .flow/config.yaml: install never touches it again, so it is unloaded on its own.
    case 'job.uninstall': {
      const job = args['job'] ?? '';
      if (!FLOW_JOBS.includes(job)) return fail(`job.uninstall needs one of ${FLOW_JOBS.join(', ')}`);
      return sh('jobs.sh', ['uninstall', job], [`job:${job}`], SCRIPT_TIMEOUT_MS, ['jobs']);
    }
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

/**
 * `terminal.open`: a terminal window in the project root, a pool worktree, another worktree git
 * lists for the project, or the folder of an agent or session the snapshot lists, nowhere else. With `job` (from the root only) the window follows that
 * job's log, `<root>/.flow/log/<job>.log`. Nothing is locked or re-read: it only opens a window.
 */
function planTerminal(args: Record<string, string>, context: ActionContext): PlanResult {
  const asked = args['path'] ?? '';
  if (!path.isAbsolute(asked)) return fail('terminal.open needs an absolute path');
  const folder = path.resolve(asked);
  const allowed = [context.root, ...context.pool, ...context.outsideWorktrees, ...context.processCwds].map((entry) => path.resolve(entry));
  const session = args['session'];
  if (session !== undefined) return planSession(folder, session, args, context);
  if (!allowed.includes(folder)) return fail(`${folder} is not the project root, a worktree the console lists or the folder of a listed agent or session`);
  let run: string[] | null = null;
  const job = args['job'];
  if (job !== undefined) {
    if (!JOB_NAME.test(job)) return fail('terminal.open needs a job name like next or health');
    if (folder !== path.resolve(context.root)) return fail("a job's log opens from the project root");
    const flowHome = path.join(path.resolve(context.root), '.flow');
    const log = path.join(flowHome, 'log', `${job}.log`);
    if (path.relative(flowHome, log).startsWith('..')) return fail("a job's log must be under the project's .flow");
    run = ['tail', '-n', LOG_LINES, '-f', log];
  }
  const launch = terminalLaunch(context.terminal, context.installedTerminals, folder, run);
  if (!launch.ok) return launch;
  return { ok: true, plan: { command: launch.launch.command, args: launch.launch.args, cwd: context.root, locks: [], timeoutMs: SCRIPT_TIMEOUT_MS, detach: false, refresh: [], refreshAgainMs: null, outcome: 'finished' } };
}

/**
 * `terminal.open` with `session` (a pid): a terminal at the folder that process ran in, with its
 * resume command typed but not run while the process still runs, or run at once once it ended.
 * Only a session the snapshot lists, and only in its own folder: `claude --resume` finds a
 * session by the folder it was started in.
 */
function planSession(folder: string, pid: string, args: Record<string, string>, context: ActionContext): PlanResult {
  if (!PID.test(pid)) return fail('session must be the pid of an agent or session the console lists');
  if (args['job'] !== undefined) return fail('terminal.open takes a job or a session, not both');
  const found = context.sessions.find((entry) => String(entry.pid) === pid);
  if (found === undefined) return fail(`the console knows no session for pid ${pid}: its transcript was not found, or it ended over a day ago`);
  if (path.resolve(found.cwd) !== folder) return fail(`pid ${pid} ran in ${found.cwd}; its session opens there, not in ${folder}`);
  const launch = sessionLaunch(context.terminal, context.installedTerminals, folder, found.session.resume, found.alive);
  if (!launch.ok) return launch;
  return { ok: true, plan: { command: launch.launch.command, args: launch.launch.args, cwd: context.root, locks: [], timeoutMs: SCRIPT_TIMEOUT_MS, detach: false, refresh: [], refreshAgainMs: null, outcome: 'finished' } };
}

/**
 * `worktree.sync`: merge the base (and the branch's own upstream first, when it is ahead) into a
 * claimed pool worktree. Refused while the worktree has uncommitted files, a run record names its
 * item, or an agent works in it, each with its own reason, since a merge under any of those would
 * mix with work in progress.
 */
function planSync(args: Record<string, string>, context: ActionContext): PlanResult {
  const target = args['target'] ?? '';
  const worktree = ITEM_ID.test(target)
    ? context.worktrees.find((entry) => entry.item === target)
    : context.worktrees.find((entry) => entry.name === target && context.pool.includes(entry.path));
  if (worktree === undefined) return fail(`worktree.sync needs an item claimed in the pool or the name of a pool worktree; ${target === '' ? 'none given' : `${target} is neither`}`);
  if (worktree.item === null) return fail(`${worktree.name} is not claimed, so it has no branch to bring up to date`);
  if (worktree.dirtyFiles === null) return fail(`git has not read ${worktree.name} yet; try again in a moment`);
  if (worktree.dirtyFiles > 0) return fail(`${worktree.name} has ${worktree.dirtyFiles} uncommitted file${worktree.dirtyFiles === 1 ? '' : 's'}; commit or stash them before merging`);
  if (context.runItems.includes(worktree.item)) return fail(`a run record names ${worktree.item}; let the run end (or run the health check if it died) before merging`);
  if (worktree.agentPids.length > 0) return fail(`an agent works in ${worktree.name} (pid ${worktree.agentPids.join(', ')}); merging under it would mix with its work`);
  const base = worktree.claimBase ?? context.base;
  if (!BRANCH.test(base) || base.includes('..')) return fail(`the base ${base} is not a branch name git can merge`);
  return {
    ok: true,
    plan: { command: 'sh', args: [SYNC_SCRIPT, worktree.path, base], cwd: worktree.path, locks: [`item:${worktree.item}`, `worktree:${worktree.path}`], timeoutMs: MERGE_TIMEOUT_MS, detach: false, refresh: ['git'], refreshAgainMs: null, outcome: 'finished' },
  };
}
