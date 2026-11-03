import type { Item, ItemState, PullRequest, PullState } from '../../daemon/src/snapshot.ts';
import { clockTime } from './clock.tsx';
import type { Tone } from './status.ts';

/** One row of the pull request table, whatever the source of the list. */
export type PullRequestRow = { item: string; title: string; pr: string; url: string | null; state: ItemState; worktree: string | null };

const PR_NUMBER = /(\d+)\s*$/;

/** Rows from the open items that carry a PR; a done item's PR is merged. The snapshot's own pull request list will replace this source. */
export function pullRowsFromItems(items: Item[], repo: string | null): PullRequestRow[] {
  return items.filter((item) => item.pr !== null && item.pr !== '' && item.state !== 'done').map((item) => ({
    item: item.id,
    title: item.title,
    pr: pullLabel(item.pr ?? ''),
    url: pullUrl(item.pr ?? '', repo),
    state: item.state,
    worktree: item.worktree,
  }));
}

export function pullLabel(pr: string): string {
  const number = PR_NUMBER.exec(pr.replace(/\/+$/, ''))?.[1];
  return number === undefined ? pr : `#${number}`;
}

export function pullUrl(pr: string, repo: string | null): string | null {
  if (/^https?:\/\//.test(pr)) return pr;
  const number = PR_NUMBER.exec(pr)?.[1];
  if (number === undefined || repo === null) return null;
  return `https://github.com/${repo}/pull/${number}`;
}

/** What each pull state says on a card, in the words the README's glossary uses. */
export const PULL_STATE_LABEL: Record<PullState, string> = {
  draft: 'draft',
  conflicts: 'conflicts',
  'checks-failing': 'checks failing',
  'checks-pending': 'checks running',
  'changes-requested': 'changes requested',
  'review-pending': 'review pending',
  'in-review': 'in review',
  approved: 'approved',
  mergeable: 'ready to merge',
};

/** One cell of a pull's health strip: what it measures, where it stands, a line of detail, and its tone. */
export type HealthCell = { label: string; value: string; sub: string; tone: Tone };

/** A list as a sentence says it: `codex`, `codex and bob`, `codex, bob and carol`. */
export function namesSaid(names: readonly string[]): string {
  return names.length < 2 ? names.join('') : `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

/** The checks, conflicts, review and threads of one pull, each in one cell. */
export function healthCells(pull: PullRequest): HealthCell[] {
  return [checksCell(pull), conflictsCell(pull), reviewCell(pull), threadsCell(pull)];
}

function checksCell({ checks }: PullRequest): HealthCell {
  const sub = `${checks.passed} passed · ${checks.failed} failed · ${checks.pending} running`;
  if (checks.failed > 0) return { label: 'Checks', value: `${checks.failed} failed`, sub, tone: 'failing' };
  if (checks.pending > 0) return { label: 'Checks', value: `${checks.pending} running`, sub, tone: 'running' };
  if (checks.passed > 0) return { label: 'Checks', value: `all ${checks.passed} passed`, sub, tone: 'quiet' };
  return { label: 'Checks', value: 'none', sub: 'no check reported', tone: 'quiet' };
}

function conflictsCell(pull: PullRequest): HealthCell {
  const sub = `${pull.branch} → ${pull.base}`;
  if (pull.state === 'conflicts' || pull.mergeable === 'CONFLICTING') return { label: 'Conflicts', value: 'conflicts', sub, tone: 'failing' };
  if (pull.mergeable === 'MERGEABLE') return { label: 'Conflicts', value: 'none', sub, tone: 'quiet' };
  return { label: 'Conflicts', value: 'not known yet', sub, tone: 'quiet' };
}

const REVIEW_DECISION: Record<string, { value: string; tone: Tone }> = {
  APPROVED: { value: 'approved', tone: 'ready' },
  CHANGES_REQUESTED: { value: 'changes requested', tone: 'review' },
  REVIEW_REQUIRED: { value: 'approval required', tone: 'quiet' },
};

/** A reviewer that cannot review comes first: the pull waits without that review until you act. */
function reviewCell(pull: PullRequest): HealthCell {
  const review = pull.review;
  const sub = review === null ? 'no health record' : `health read ${clockTime(review.at)}`;
  if (review !== null && review.cannot.length > 0) return { label: 'Review', value: `${namesSaid(review.cannot.map((entry) => entry.reviewer))} cannot review`, sub, tone: 'needs-you' };
  if (pull.state === 'in-review' && review !== null) return { label: 'Review', value: `waiting on ${namesSaid(review.waiting)}`, sub, tone: 'running' };
  const decision = REVIEW_DECISION[pull.reviewDecision ?? ''];
  if (decision !== undefined) return { label: 'Review', ...decision, sub };
  return { label: 'Review', value: 'none yet', sub, tone: 'quiet' };
}

function threadsCell({ unresolvedThreads }: PullRequest): HealthCell {
  return unresolvedThreads > 0
    ? { label: 'Threads', value: `${unresolvedThreads} open`, sub: 'the comments job answers them', tone: 'needs-you' }
    : { label: 'Threads', value: '0 open', sub: 'all resolved', tone: 'quiet' };
}

/** Why Merge is not offered on a pull that is not ready, in one sentence, or null when it is ready. */
export function mergeBlockedReason(pull: PullRequest): string | null {
  switch (pull.state) {
    case 'mergeable': return null;
    case 'draft': return 'A draft cannot be merged; mark it ready on GitHub first.';
    case 'conflicts': return 'Merge is off until the branch merges the base cleanly.';
    case 'checks-failing': return 'Merge is off while checks fail.';
    case 'checks-pending': return 'Merge waits for the running checks.';
    case 'changes-requested': return 'Merge is off while changes are requested.';
    case 'review-pending': return 'Merge waits for a review on GitHub.';
    case 'in-review': return `Merge waits on ${namesSaid(pull.review?.waiting ?? [])}, asked by a mention and not answered yet.`;
    case 'approved': return 'Approved; merge waits for open threads or GitHub\'s merge check.';
  }
}

/** GitHub's merge states that refuse a plain merge which `gh pr merge --admin` goes past: a rule not met, or a branch behind its base. */
const GITHUB_BLOCKING_MERGE_STATES = ['BLOCKED', 'BEHIND'];

/**
 * Whether the card offers Force merge, which merges past what branch protection requires: on a
 * pull whose checks fail, or one that is approved while GitHub still blocks the merge. Never on a
 * draft, a conflict (nothing can merge it), running checks or requested changes, which a reviewer
 * or a run is still answering.
 */
export function forceMergeOffered(pull: PullRequest): boolean {
  if (pull.state === 'checks-failing') return true;
  return pull.state === 'approved' && GITHUB_BLOCKING_MERGE_STATES.includes(pull.mergeState ?? '');
}
