import type { FlowEvent, Item, ItemState, PullCheck, PullRequest, PullState } from '../../daemon/src/snapshot.ts';
import { mentionReviewWaiting, reviewChangesRequested } from '../../daemon/src/snapshot.ts';
import { clockTime, formatDuration } from './clock.tsx';
import { eventTone, pullTone } from './status.ts';
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

/** How many characters of a commit the card shows, as GitHub's own short form. */
export const SHORT_SHA = 8;

/** The state, checks, conflicts, review, threads and quiz of one pull, each in one cell. */
export function healthCells(pull: PullRequest, takenAt: string): HealthCell[] {
  return [stateCell(pull, takenAt), checksCell(pull), conflictsCell(pull), reviewCell(pull), threadsCell(pull), quizCell(pull)];
}

/** When the pull opened: the time on the snapshot's day, else how long ago; and how long it has been idle. */
function stateCell(pull: PullRequest, takenAt: string): HealthCell {
  const sameDay = new Date(pull.createdAt).toDateString() === new Date(takenAt).toDateString();
  const opened = sameDay ? `opened ${clockTime(pull.createdAt)}` : `opened ${formatDuration(pull.ageSeconds)} ago`;
  return { label: 'State', value: PULL_STATE_LABEL[pull.state], sub: `${opened} · idle ${formatDuration(pull.idleSeconds)}`, tone: pullTone(pull.state) };
}

function checksCell({ checks }: PullRequest): HealthCell {
  const sub = `${checks.passed} passed · ${checks.failed} failed · ${checks.pending} running`;
  if (checks.failed > 0) return { label: 'Checks', value: `${checks.failed} failed`, sub, tone: 'failing' };
  if (checks.pending > 0) return { label: 'Checks', value: `${checks.pending} running`, sub, tone: 'running' };
  if (checks.passed > 0) return { label: 'Checks', value: `all ${checks.passed} passed`, sub, tone: 'quiet' };
  return { label: 'Checks', value: 'none', sub: 'no check reported', tone: 'quiet' };
}

function conflictsCell(pull: PullRequest): HealthCell {
  const sub = pull.head === null ? `${pull.branch} → ${pull.base}` : `head ${pull.head.slice(0, SHORT_SHA)}`;
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

/** The quiz of the pull's item: a draft with one goes ready for review once you pass it. */
function quizCell({ quiz }: PullRequest): HealthCell {
  if (quiz === null) return { label: 'Quiz', value: 'none', sub: 'no quiz on this item', tone: 'quiet' };
  const asked = `${quiz.questions.length} question${quiz.questions.length === 1 ? '' : 's'}`;
  if (quiz.result === null) return { label: 'Quiz', value: 'not taken', sub: `${asked} · take it below`, tone: 'needs-you' };
  const score = `${quiz.result.right} of ${quiz.result.total} right`;
  return quiz.result.passed
    ? { label: 'Quiz', value: 'passed', sub: score, tone: 'quiet' }
    : { label: 'Quiz', value: 'not passed', sub: `${score} · try again below`, tone: 'needs-you' };
}

/** One row of a pull's check list: a single check, or the passed ones folded into one row. */
export type CheckRow = { name: string; outcome: PullCheck['outcome']; sub: string; url: string | null };

const CHECK_SAID: Record<PullCheck['outcome'], string> = { failed: 'failed', pending: 'running since', passed: 'passed' };

/**
 * The checks as the card lists them: each failed and each running check on its own row, then the
 * passed ones folded into one, since a passed check needs nothing from anyone.
 */
export function checkRows(checks: readonly PullCheck[]): CheckRow[] {
  const open = checks.filter((check) => check.outcome !== 'passed').map((check) => ({
    name: check.name, outcome: check.outcome, url: check.url,
    sub: check.at === null ? (check.outcome === 'pending' ? 'queued' : CHECK_SAID[check.outcome]) : `${CHECK_SAID[check.outcome]} ${clockTime(check.at)}`,
  }));
  const passed = checks.length - open.length;
  if (passed === 0) return open;
  const name = open.length === 0 ? `All ${passed} check${passed === 1 ? '' : 's'}` : `${passed} other check${passed === 1 ? '' : 's'}`;
  return [...open, { name, outcome: 'passed', sub: 'passed', url: null }];
}

/** One moment on a pull's Today timeline. */
export type TimelineEntry = { at: string; text: string; tone: Tone };

/** How many moments a card's timeline shows at most. */
export const TIMELINE_SHOWN = 8;

/**
 * What happened to the pull since local midnight of the snapshot's day, newest first: the flow's
 * events on its item, and its opening when that was today.
 */
export function pullTimeline(pull: PullRequest, events: readonly FlowEvent[], takenAt: string): TimelineEntry[] {
  const day = new Date(takenAt).toDateString();
  const today = (at: string): boolean => new Date(at).toDateString() === day;
  const entries: TimelineEntry[] = pull.item === null ? [] : events
    .filter((event) => event.item === pull.item && today(event.at))
    .map((event) => ({ at: event.at, text: `${event.kind}: ${event.message}`, tone: eventTone(event) }));
  if (today(pull.createdAt)) entries.push({ at: pull.createdAt, text: `PR opened by ${pull.author}`, tone: 'quiet' });
  return entries.sort((a, b) => b.at.localeCompare(a.at)).slice(0, TIMELINE_SHOWN);
}

/**
 * Whether a review holds the pull that GitHub's auto-merge may merge past: it waits only for what
 * branch protection requires, so not for a reviewer asked by a mention, a review requested but
 * not required, an optional request for changes or an open thread. The plain Merge waits for each.
 */
function reviewHolds(pull: PullRequest): boolean {
  if (pull.review !== null && mentionReviewWaiting(pull.review.waiting)) return true;
  return reviewChangesRequested(pull) || pull.reviewsRequested > 0 || pull.unresolvedThreads > 0;
}

/**
 * Whether the card offers Merge when green, GitHub's auto-merge: on a pull that waits for checks
 * or a required review to pass. Never on a draft or a conflict, which no wait can merge, nor on a
 * pull ready to merge now, nor while a review holds it (`reviewHolds`), whatever its checks show.
 * An armed pull always offers Disarm.
 */
export function autoMergeOffered(pull: PullRequest): boolean {
  if (pull.autoMerge !== null) return true;
  if (reviewHolds(pull)) return false;
  return !['draft', 'conflicts', 'mergeable'].includes(pull.state);
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
