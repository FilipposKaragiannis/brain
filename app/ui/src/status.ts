import type { AttentionKind, Freshness, ItemState, Job, PullState, WorktreeState } from '../../daemon/src/snapshot.ts';
import type { ActionRecord, ActionState } from './actions.ts';

/**
 * The console's one status language. Every state anywhere on the page maps to one of five tones:
 * green pulse for running, orange breathing for needs-you, purple hatching for stale, grey for
 * free or claimed, red for failing.
 */
export type Tone = 'running' | 'needs-you' | 'stale' | 'quiet' | 'failing';

export function worktreeTone(state: WorktreeState): Tone {
  switch (state) {
    case 'running': return 'running';
    case 'needs-you': return 'needs-you';
    case 'stale': return 'stale';
    case 'claimed': case 'free': case 'outside': return 'quiet';
  }
}

export function itemTone(state: ItemState): Tone {
  switch (state) {
    case 'running': return 'running';
    case 'needs-you': return 'needs-you';
    case 'stale': return 'stale';
    case 'claimed': case 'ready': case 'blocked': case 'backlog': case 'done': return 'quiet';
  }
}

export function attentionTone(kind: AttentionKind): Tone {
  switch (kind) {
    case 'gate': return 'needs-you';
    case 'stale': return 'stale';
    case 'dead-run': case 'disagreement': case 'job-failed': case 'pr-failing': return 'failing';
    case 'pr-changes-requested': case 'pr-mergeable': case 'needs-field': return 'needs-you';
  }
}

export function pullTone(state: PullState): Tone {
  switch (state) {
    case 'mergeable': case 'changes-requested': return 'needs-you';
    case 'checks-failing': case 'conflicts': return 'failing';
    case 'checks-pending': case 'review-pending': return 'running';
    case 'draft': case 'approved': return 'quiet';
  }
}

export function jobTone(job: Job): Tone {
  if (job.state === 'running') return 'running';
  if (job.state === 'not-loaded') return 'failing';
  if (job.last !== null && job.last.exit !== null && job.last.exit !== 0) return 'failing';
  return 'quiet';
}

export function actionTone(state: ActionState): Tone {
  switch (state) {
    case 'running': return 'running';
    case 'done': return 'quiet';
    case 'failed': case 'rejected': return 'failing';
  }
}

/** A record's tone: an action that started work elsewhere reads as live work, not as finished. */
export function actionRecordTone(record: ActionRecord): Tone {
  if (record.state === 'done' && record.outcome === 'started') return 'running';
  return actionTone(record.state);
}

export function freshnessTone(freshness: Freshness): Tone {
  return freshness.ok ? 'quiet' : 'failing';
}

export function countTone(count: number, tone: Tone): Tone {
  return count > 0 ? tone : 'quiet';
}
