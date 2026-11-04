import type { AttentionKind, FlowEvent, Freshness, ItemState, Job, PullState, WorktreeState } from '../../daemon/src/snapshot.ts';
import type { ActionRecord, ActionState } from './actions.ts';

/**
 * The console's one status language. Every state anywhere on the page maps to one of eight tones:
 * green pulse for running, orange breathing for needs-you, purple hatching for stale, grey for
 * free or claimed, red for failing, teal for ready (a pull that can merge), blue for review (changes
 * asked on a pull) and pink for mixed (two stores that disagree).
 */
export type Tone = 'running' | 'needs-you' | 'stale' | 'quiet' | 'failing' | 'ready' | 'review' | 'mixed';

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
    // A reviewer is at work on it: live work, though not an agent of the flow's.
    case 'in-review': return 'running';
    case 'claimed': case 'ready': case 'blocked': case 'backlog': case 'done': return 'quiet';
  }
}

export function attentionTone(kind: AttentionKind): Tone {
  switch (kind) {
    case 'gate': return 'needs-you';
    case 'stale': return 'stale';
    case 'dead-run': case 'job-failed': case 'pr-failing': case 'host-stopped': return 'failing';
    case 'disagreement': return 'mixed';
    case 'pr-mergeable': return 'ready';
    case 'pr-changes-requested': return 'review';
    case 'needs-field': return 'quiet';
  }
}

export function pullTone(state: PullState): Tone {
  switch (state) {
    case 'mergeable': case 'approved': return 'ready';
    case 'changes-requested': return 'review';
    case 'checks-failing': case 'conflicts': return 'failing';
    case 'checks-pending': case 'review-pending': case 'in-review': return 'running';
    case 'draft': return 'quiet';
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

/** How a flow event went, from its kind: a failure, a question for you, work starting, or news. */
export function eventTone(event: FlowEvent): Tone {
  if (/fail|dead|error|refus/i.test(event.kind)) return 'failing';
  if (/gate|ambiguity|approval|escalation|feel-test|decomposition/i.test(event.kind)) return 'needs-you';
  if (/start|resume|step|claim/i.test(event.kind)) return 'running';
  return 'quiet';
}
