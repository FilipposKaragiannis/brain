import { useState } from 'react';
import { ActionButton } from './ui.tsx';

const OTHER = '__other__';
/** The reviewers the flow knows how to ask by name, as `pr.review` takes them. */
const SUPPORTED_REVIEWERS = ['codex', 'claude', 'copilot'];

/** The project's reviewers first, then every supported reviewer not among them. */
function reviewerChoices(reviewers: readonly string[]): string[] {
  const named = new Set(reviewers.map((name) => name.toLowerCase()));
  return [...reviewers, ...SUPPORTED_REVIEWERS.filter((name) => !named.has(name))];
}

/**
 * Ask one reviewer for a review of a PR: the project's `reviews.reviewers` to pick from, then the
 * other reviewers the flow supports, or any GitHub login. `pr.review` posts the same mention the
 * PR step does, so the health job tracks and chases the ask.
 */
export function AskReview({ pr, reviewers }: { pr: number; reviewers: string[] }) {
  const choices = reviewerChoices(reviewers);
  const [picked, setPicked] = useState(choices[0] ?? OTHER);
  const [login, setLogin] = useState('');
  const reviewer = picked === OTHER ? login.trim().replace(/^@/, '') : picked;
  return (
    <span className="ask-review">
      <label className="muted" htmlFor={`ask-review-${pr}`}>Ask for review from</label>
      <select id={`ask-review-${pr}`} className="input" value={picked} onChange={(event) => setPicked(event.target.value)}>
        {choices.map((name) => <option key={name} value={name}>{name}</option>)}
        <option value={OTHER}>other…</option>
      </select>
      {picked === OTHER && <input className="input mono" aria-label="GitHub login" type="text" placeholder="GitHub login" value={login} onChange={(event) => setLogin(event.target.value)} />}
      {reviewer === ''
        ? <button type="button" className="button" disabled={true}>Ask</button>
        : <ActionButton kind="pr.review" args={{ pr: String(pr), reviewer }} label="Ask" primary={false} title={`Posts "@${reviewer} please review…" on #${pr}`} />}
    </span>
  );
}
