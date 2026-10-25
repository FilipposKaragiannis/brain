import type { AttentionKind, Freshness, ItemState, Job, WorktreeState } from '../../daemon/src/snapshot.ts';
import type { ActionState } from './actions.ts';

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
    case 'dead-run': case 'disagreement': case 'job-failed': return 'failing';
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

export function freshnessTone(freshness: Freshness): Tone {
  return freshness.ok ? 'quiet' : 'failing';
}

export function countTone(count: number, tone: Tone): Tone {
  return count > 0 ? tone : 'quiet';
}
