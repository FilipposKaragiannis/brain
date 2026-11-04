import type { CommandResult, CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** How a pull request's checks stand: each check counted once, by its latest run. */
export type CheckCounts = { passed: number; failed: number; pending: number };

/** One check on the pull's head by its latest run: when it ended (or started, while it runs) and the page of its run. */
export type CheckRun = { name: string; outcome: keyof CheckCounts; at: string | null; url: string | null };

/** GitHub's auto-merge on the pull: the method it merges with once every requirement is met, and since when. */
export type AutoMerge = { method: string; at: string };

/** One open pull request as the console needs it. No `gh` shape leaks past this file. */
export type PullFact = {
  number: number;
  title: string;
  url: string;
  branch: string;
  base: string;
  author: string;
  draft: boolean;
  crossRepository: boolean;
  mergeable: string | null;
  mergeState: string | null;
  reviewDecision: string | null;
  changesRequested: number;
  /** Reviews asked and not given yet: a reviewer still requested on the pull. */
  reviewsRequested: number;
  checks: CheckCounts;
  /** The checks one by one: failed first, then running, then passed. */
  checkRuns: CheckRun[];
  /** The head commit, or null when GitHub gave none. */
  head: string | null;
  autoMerge: AutoMerge | null;
  unresolvedThreads: number;
  createdAt: string;
  updatedAt: string;
};

/** A pull merged since local midnight. */
export type MergedFact = { number: number; title: string; url: string; branch: string; createdAt: string; mergedAt: string };

export type PullFacts = { pulls: PullFact[]; merged: MergedFact[] };

const GH_TIMEOUT_MS = 60000;
const MILLISECONDS_PER_SECOND = 1000;
/** GitHub's own page size: `gh pr list` and a GraphQL connection both stop at 100. */
const PAGE_SIZE = 100;
const PULL_FIELDS = [
  'number', 'title', 'url', 'headRefName', 'baseRefName', 'isDraft', 'isCrossRepository', 'mergeable', 'mergeStateStatus',
  'reviewDecision', 'statusCheckRollup', 'updatedAt', 'createdAt', 'author', 'latestReviews', 'reviewRequests',
  'headRefOid', 'autoMergeRequest',
].join(',');
const MERGED_FIELDS = ['number', 'title', 'url', 'headRefName', 'createdAt', 'mergedAt'].join(',');
const PASSED_CONCLUSIONS = ['SUCCESS', 'NEUTRAL', 'SKIPPED'];
const PENDING_STATUSES = ['PENDING', 'EXPECTED'];
/** gh prints this start time for a run that is queued and has not started. */
const NOT_STARTED_PREFIX = '0001-';

type RollupEntry = {
  __typename?: string; name?: string; context?: string; workflowName?: string;
  status?: string; conclusion?: string | null; state?: string; startedAt?: string | null;
  completedAt?: string | null; detailsUrl?: string; targetUrl?: string;
};
type ListedPull = {
  number?: number; title?: string; url?: string; headRefName?: string; baseRefName?: string;
  isDraft?: boolean; isCrossRepository?: boolean; mergeable?: string; mergeStateStatus?: string; reviewDecision?: string;
  statusCheckRollup?: RollupEntry[] | null; createdAt?: string; updatedAt?: string;
  author?: { login?: string } | null;
  latestReviews?: { state?: string }[] | null;
  reviewRequests?: unknown[] | null;
  headRefOid?: string;
  autoMergeRequest?: { mergeMethod?: string; enabledAt?: string } | null;
};
type ListedMerged = { number?: number; title?: string; url?: string; headRefName?: string; createdAt?: string; mergedAt?: string };
type ThreadsResponse = {
  data?: { repository?: Record<string, { reviewThreads?: { nodes?: { isResolved?: boolean }[] } } | null> | null };
};

const orNull = (value: string | undefined): string | null => (value === undefined || value === '' ? null : value);

/** A completed run with no conclusion, or any conclusion but a pass, is a failure: it never turns green on its own. */
function checkOutcome(entry: RollupEntry): keyof CheckCounts {
  if (entry.__typename === 'StatusContext') {
    if (entry.state === 'SUCCESS') return 'passed';
    return PENDING_STATUSES.includes(entry.state ?? '') ? 'pending' : 'failed';
  }
  if (entry.status !== 'COMPLETED') return 'pending';
  return PASSED_CONCLUSIONS.includes(entry.conclusion ?? '') ? 'passed' : 'failed';
}

const notStarted = (entry: RollupEntry): boolean => !entry.startedAt || entry.startedAt.startsWith(NOT_STARTED_PREFIX);
/** A run's time, or null when gh gives none or year one: a run not started or not finished has year one. */
const runTime = (at: string | null | undefined): string | null => !at || at.startsWith(NOT_STARTED_PREFIX) ? null : at;

/** True when `entry` is a later run than `seen`: a queued run is the latest, and on a tie the unfinished one wins. */
function newer(entry: RollupEntry, seen: RollupEntry): boolean {
  if (notStarted(entry) !== notStarted(seen)) return notStarted(entry);
  const entryStart = entry.startedAt ?? '';
  const seenStart = seen.startedAt ?? '';
  if (entryStart !== seenStart) return entryStart > seenStart;
  return entry.status !== 'COMPLETED' && seen.status === 'COMPLETED';
}

/** A re-run lists a check twice; only the latest run of each workflow and name counts. */
function latestRuns(rollup: RollupEntry[]): RollupEntry[] {
  const latest = new Map<string, RollupEntry>();
  for (const entry of rollup) {
    const key = `${entry.workflowName ?? ''}/${entry.name ?? entry.context ?? ''}`;
    const seen = latest.get(key);
    if (seen === undefined || newer(entry, seen)) latest.set(key, entry);
  }
  return [...latest.values()];
}

export function countChecks(rollup: RollupEntry[]): CheckCounts {
  const counts: CheckCounts = { passed: 0, failed: 0, pending: 0 };
  for (const entry of latestRuns(rollup)) counts[checkOutcome(entry)] += 1;
  return counts;
}

const OUTCOME_ORDER: Array<keyof CheckCounts> = ['failed', 'pending', 'passed'];

/** Each check by its latest run, the failed ones first, then the running, then the passed, by name within each. */
export function checkRuns(rollup: RollupEntry[]): CheckRun[] {
  const runs = latestRuns(rollup).map((entry): CheckRun => ({
    name: entry.name ?? entry.context ?? '',
    outcome: checkOutcome(entry),
    at: runTime(entry.completedAt) ?? runTime(entry.startedAt),
    url: orNull(entry.detailsUrl ?? entry.targetUrl),
  }));
  return runs.sort((a, b) => OUTCOME_ORDER.indexOf(a.outcome) - OUTCOME_ORDER.indexOf(b.outcome) || a.name.localeCompare(b.name));
}

function toPullFact(listed: ListedPull): PullFact {
  return {
    number: listed.number ?? 0,
    title: listed.title ?? '',
    url: listed.url ?? '',
    branch: listed.headRefName ?? '',
    base: listed.baseRefName ?? '',
    author: listed.author?.login ?? '',
    draft: listed.isDraft === true,
    crossRepository: listed.isCrossRepository === true,
    mergeable: orNull(listed.mergeable),
    mergeState: orNull(listed.mergeStateStatus),
    reviewDecision: orNull(listed.reviewDecision),
    changesRequested: (listed.latestReviews ?? []).filter((review) => review.state === 'CHANGES_REQUESTED').length,
    reviewsRequested: (listed.reviewRequests ?? []).length,
    checks: countChecks(listed.statusCheckRollup ?? []),
    checkRuns: checkRuns(listed.statusCheckRollup ?? []),
    head: orNull(listed.headRefOid),
    autoMerge: autoMerge(listed.autoMergeRequest),
    unresolvedThreads: 0,
    createdAt: listed.createdAt ?? '',
    updatedAt: listed.updatedAt ?? '',
  };
}

function autoMerge(request: ListedPull['autoMergeRequest']): AutoMerge | null {
  if (request === null || request === undefined) return null;
  return { method: request.mergeMethod ?? '', at: request.enabledAt ?? '' };
}

/** `gh pr list --json` into pull facts, before the thread counts are known. */
export function parsePullList(source: string): PullFact[] {
  const parsed: unknown = JSON.parse(source);
  return Array.isArray(parsed) ? (parsed as ListedPull[]).map(toPullFact) : [];
}

/** `gh pr list --state merged --json` into the pulls merged at or after `since`; GitHub's search goes by the day, so the time is checked here. */
export function parseMergedList(source: string, since: Date): MergedFact[] {
  const parsed: unknown = JSON.parse(source);
  if (!Array.isArray(parsed)) return [];
  return (parsed as ListedMerged[])
    .map((listed) => ({ number: listed.number ?? 0, title: listed.title ?? '', url: listed.url ?? '', branch: listed.headRefName ?? '', createdAt: listed.createdAt ?? '', mergedAt: listed.mergedAt ?? '' }))
    .filter((merged) => Date.parse(merged.mergedAt) >= since.getTime())
    .sort((a, b) => b.mergedAt.localeCompare(a.mergedAt));
}

/** Local midnight of the day `now` falls on: where the page's "today" starts. */
export function startOfDay(now: Date): Date {
  return new Date(now.getFullYear(), now.getMonth(), now.getDate());
}

const alias = (pullNumber: number): string => `pr${pullNumber}`;

/** One query for every pull's review threads, one alias per pull. 100 pulls of 100 threads stays far under GitHub's node limit. */
export function threadsQuery(numbers: number[]): string {
  const fields = numbers.map((pullNumber) => `${alias(pullNumber)}: pullRequest(number: ${pullNumber}) { reviewThreads(first: ${PAGE_SIZE}) { nodes { isResolved } } }`);
  return `query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { ${fields.join(' ')} } }`;
}

/** The GraphQL answer into unresolved thread counts by pull number. */
export function parseThreadCounts(source: string, numbers: number[]): Map<number, number> {
  const repository = (JSON.parse(source) as ThreadsResponse).data?.repository ?? {};
  return new Map(numbers.map((pullNumber) => {
    const nodes = repository[alias(pullNumber)]?.reviewThreads?.nodes ?? [];
    return [pullNumber, nodes.filter((node) => node.isResolved === false).length];
  }));
}

function failure(command: string, result: CommandResult): Error {
  if (result.timedOut) return new Error(`${command} timed out after ${GH_TIMEOUT_MS / MILLISECONDS_PER_SECOND}s`);
  const reason = result.stderr.trim() || (result.code === null ? 'killed without an exit code' : `exit code ${result.code}`);
  return new Error(`${command} failed: ${reason}`);
}

export async function readPulls(root: string, repo: string, runner: CommandRunner, now: Date): Promise<PullFacts> {
  const env = scriptEnvironment();
  const listing = await runner({
    command: 'gh',
    args: ['pr', 'list', '--repo', repo, '--state', 'open', '--limit', String(PAGE_SIZE), '--json', PULL_FIELDS],
    cwd: root, timeoutMs: GH_TIMEOUT_MS, env,
  });
  if (listing.code !== 0 || listing.timedOut) throw failure('gh pr list', listing);
  const since = startOfDay(now);
  const mergedListing = await runner({
    command: 'gh',
    args: ['pr', 'list', '--repo', repo, '--state', 'merged', '--search', `merged:>=${since.toISOString().slice(0, 10)}`, '--limit', String(PAGE_SIZE), '--json', MERGED_FIELDS],
    cwd: root, timeoutMs: GH_TIMEOUT_MS, env,
  });
  if (mergedListing.code !== 0 || mergedListing.timedOut) throw failure('gh pr list --state merged', mergedListing);
  const merged = parseMergedList(mergedListing.stdout, since);
  const pulls = parsePullList(listing.stdout);
  if (pulls.length === 0) return { pulls, merged };
  const [owner, name] = repo.split('/');
  const numbers = pulls.map((pull) => pull.number);
  const threads = await runner({
    command: 'gh',
    args: ['api', 'graphql', '-f', `query=${threadsQuery(numbers)}`, '-f', `owner=${owner ?? ''}`, '-f', `name=${name ?? ''}`],
    cwd: root, timeoutMs: GH_TIMEOUT_MS, env,
  });
  if (threads.code !== 0 || threads.timedOut) throw failure('gh api graphql (review threads)', threads);
  const counts = parseThreadCounts(threads.stdout, numbers);
  return { pulls: pulls.map((pull) => ({ ...pull, unresolvedThreads: counts.get(pull.number) ?? 0 })), merged };
}
