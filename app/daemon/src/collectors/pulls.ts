import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** How a pull request's checks stand: each check counted once, by its latest run. */
export type CheckCounts = { passed: number; failed: number; pending: number };

/** One open pull request as the console needs it. No `gh` shape leaks past this file. */
export type PullFact = {
  number: number;
  title: string;
  url: string;
  branch: string;
  base: string;
  head: string;
  author: string;
  draft: boolean;
  mergeable: string | null;
  mergeState: string | null;
  reviewDecision: string | null;
  approvals: number;
  changesRequested: number;
  requestedReviewers: string[];
  checks: CheckCounts;
  unresolvedThreads: number;
  createdAt: string;
  updatedAt: string;
};

export type PullFacts = { pulls: PullFact[] };

const GH_TIMEOUT_MS = 60000;
/** GitHub's own page size: `gh pr list` and a GraphQL connection both stop at 100. */
const PAGE_SIZE = 100;
const PULL_FIELDS = [
  'number', 'title', 'url', 'headRefName', 'baseRefName', 'isDraft', 'mergeable', 'mergeStateStatus', 'reviewDecision',
  'statusCheckRollup', 'updatedAt', 'createdAt', 'headRefOid', 'author', 'latestReviews', 'reviewRequests',
].join(',');
const PASSED_CONCLUSIONS = ['SUCCESS', 'NEUTRAL', 'SKIPPED'];
const FAILED_CONCLUSIONS = ['FAILURE', 'ERROR', 'CANCELLED', 'TIMED_OUT', 'ACTION_REQUIRED', 'STARTUP_FAILURE'];

type RollupEntry = {
  __typename?: string; name?: string; context?: string; workflowName?: string;
  status?: string; conclusion?: string; state?: string; startedAt?: string;
};
type ListedPull = {
  number?: number; title?: string; url?: string; headRefName?: string; baseRefName?: string; headRefOid?: string;
  isDraft?: boolean; mergeable?: string; mergeStateStatus?: string; reviewDecision?: string;
  statusCheckRollup?: RollupEntry[] | null; createdAt?: string; updatedAt?: string;
  author?: { login?: string } | null;
  latestReviews?: { state?: string; author?: { login?: string } | null }[] | null;
  reviewRequests?: { login?: string; name?: string; slug?: string }[] | null;
};
type ThreadsResponse = {
  data?: { repository?: Record<string, { reviewThreads?: { nodes?: { isResolved?: boolean }[] } } | null> | null };
};

const orNull = (value: string | undefined): string | null => (value === undefined || value === '' ? null : value);

function checkOutcome(entry: RollupEntry): keyof CheckCounts {
  const conclusion = entry.conclusion || entry.state || '';
  if (entry.__typename === 'CheckRun' && entry.status !== 'COMPLETED') return 'pending';
  if (PASSED_CONCLUSIONS.includes(conclusion)) return 'passed';
  if (FAILED_CONCLUSIONS.includes(conclusion)) return 'failed';
  return 'pending';
}

/** A re-run lists a check twice; only the latest start of each workflow and name counts. */
export function countChecks(rollup: RollupEntry[]): CheckCounts {
  const latest = new Map<string, RollupEntry>();
  for (const entry of rollup) {
    const key = `${entry.workflowName ?? ''}/${entry.name ?? entry.context ?? ''}`;
    const seen = latest.get(key);
    if (seen === undefined || (entry.startedAt ?? '') > (seen.startedAt ?? '')) latest.set(key, entry);
  }
  const counts: CheckCounts = { passed: 0, failed: 0, pending: 0 };
  for (const entry of latest.values()) counts[checkOutcome(entry)] += 1;
  return counts;
}

function toPullFact(listed: ListedPull): PullFact {
  const reviews = listed.latestReviews ?? [];
  return {
    number: listed.number ?? 0,
    title: listed.title ?? '',
    url: listed.url ?? '',
    branch: listed.headRefName ?? '',
    base: listed.baseRefName ?? '',
    head: listed.headRefOid ?? '',
    author: listed.author?.login ?? '',
    draft: listed.isDraft === true,
    mergeable: orNull(listed.mergeable),
    mergeState: orNull(listed.mergeStateStatus),
    reviewDecision: orNull(listed.reviewDecision),
    approvals: reviews.filter((review) => review.state === 'APPROVED').length,
    changesRequested: reviews.filter((review) => review.state === 'CHANGES_REQUESTED').length,
    requestedReviewers: (listed.reviewRequests ?? []).map((request) => request.login ?? request.slug ?? request.name ?? '').filter((name) => name.length > 0),
    checks: countChecks(listed.statusCheckRollup ?? []),
    unresolvedThreads: 0,
    createdAt: listed.createdAt ?? '',
    updatedAt: listed.updatedAt ?? '',
  };
}

/** `gh pr list --json` into pull facts, before the thread counts are known. */
export function parsePullList(source: string): PullFact[] {
  const parsed: unknown = JSON.parse(source);
  return Array.isArray(parsed) ? (parsed as ListedPull[]).map(toPullFact) : [];
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

export async function readPulls(root: string, repo: string, runner: CommandRunner): Promise<PullFacts> {
  const env = scriptEnvironment();
  const listing = await runner({
    command: 'gh',
    args: ['pr', 'list', '--repo', repo, '--state', 'open', '--limit', String(PAGE_SIZE), '--json', PULL_FIELDS],
    cwd: root, timeoutMs: GH_TIMEOUT_MS, env,
  });
  if (listing.code !== 0) throw new Error(`gh pr list failed: ${listing.stderr.trim() || listing.code}`);
  const pulls = parsePullList(listing.stdout);
  if (pulls.length === 0) return { pulls };
  const [owner, name] = repo.split('/');
  const numbers = pulls.map((pull) => pull.number);
  const threads = await runner({
    command: 'gh',
    args: ['api', 'graphql', '-f', `query=${threadsQuery(numbers)}`, '-f', `owner=${owner ?? ''}`, '-f', `name=${name ?? ''}`],
    cwd: root, timeoutMs: GH_TIMEOUT_MS, env,
  });
  if (threads.code !== 0) throw new Error(`gh api graphql (review threads) failed: ${threads.stderr.trim() || threads.code}`);
  const counts = parseThreadCounts(threads.stdout, numbers);
  return { pulls: pulls.map((pull) => ({ ...pull, unresolvedThreads: counts.get(pull.number) ?? 0 })) };
}
