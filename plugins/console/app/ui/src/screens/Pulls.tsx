import type { PullRequest, PullReview, Snapshot } from '../../../daemon/src/snapshot.ts';
import { AskReview } from '../askReview.tsx';
import { Age } from '../clock.tsx';
import { ExternalLink, ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { healthCells, mergeBlockedReason, PULL_STATE_LABEL, pullRowsFromItems } from '../pulls.ts';
import type { PullRequestRow } from '../pulls.ts';
import { QuizPanel } from '../Quiz.tsx';
import { itemTone, pullTone } from '../status.ts';
import { ActionButton, Chip, Dot, Empty, Module, SourceFreshness } from '../ui.tsx';

/**
 * Open pull requests from the daemon's `pulls` source, one card each: where it stands, its
 * health, its reviewers and the merge. Until that source has been read once, or on a project it
 * does not apply to, the items that carry a PR stand in as a table.
 */
export function Pulls({ snapshot }: { snapshot: Snapshot }) {
  const pullsRead = snapshot.sources.pulls.at !== null && snapshot.sources.pulls.error === null;
  if (!pullsRead) {
    const rows = pullRowsFromItems(snapshot.items, snapshot.project.repo);
    return (
      <div className="screen">
        <Module className="pulls" title="Pull requests" aside={<span className="muted">{rows.length} open</span>} footer={<SourceFreshness name="pulls" freshness={snapshot.sources.pulls} />}>
          <PullRequestTable rows={rows} pages={snapshot} />
        </Module>
      </div>
    );
  }
  const inReview = snapshot.pulls.filter((pull) => pull.state === 'in-review').length;
  const mergeable = snapshot.pulls.filter((pull) => pull.state === 'mergeable').length;
  return (
    <div className="screen">
      <p className="pulls-summary" aria-label="Summary">
        <span>{snapshot.pulls.length} open{inReview > 0 ? ` · ${inReview} in review` : ''}{mergeable > 0 ? ` · ${mergeable} ready to merge` : ''}</span>
        <SourceFreshness name="pulls" freshness={snapshot.sources.pulls} />
      </p>
      {snapshot.pulls.length === 0
        ? <Module className="pulls" title="Pull requests" aside={null} footer={null}><Empty>No open pull request.</Empty></Module>
        : snapshot.pulls.map((pull) => <PullCard key={pull.number} pull={pull} snapshot={snapshot} />)}
    </div>
  );
}

function PullCard({ pull, snapshot }: { pull: PullRequest; snapshot: Snapshot }) {
  const agent = snapshot.worktrees.find((worktree) => worktree.name === pull.worktree)?.agents[0] ?? null;
  const quizPending = pull.quiz !== null && pull.quiz.result?.passed !== true;
  const blocked = pull.state === 'draft' && quizPending ? 'A draft until you pass the quiz above; then it goes ready for review.' : mergeBlockedReason(pull);
  const review = pull.review;
  return (
    <section className="module pull-card" aria-label={`PR #${pull.number}`}>
      <header className="pull-head">
        <ExternalLink url={pull.url} className="mono pull-number">#{pull.number}</ExternalLink>
        <h2 className="clip" title={pull.title}>{pull.title}</h2>
        <Chip tone={pullTone(pull.state)}>{PULL_STATE_LABEL[pull.state]}</Chip>
        {pull.item !== null && <ItemLink id={pull.item} pages={snapshot} />}
        {agent !== null
          ? <span className="chip tone-running"><Dot tone="running" />agent in {pull.worktree} · <Age seconds={agent.elapsedSeconds} takenAt={snapshot.takenAt} /></span>
          : pull.worktree !== null && <span className="muted mono">{pull.worktree}</span>}
        <span className="muted pull-age">opened <Age seconds={pull.ageSeconds} takenAt={snapshot.takenAt} /> ago · idle <Age seconds={pull.idleSeconds} takenAt={snapshot.takenAt} /></span>
      </header>
      <div className="pull-health">
        {healthCells(pull).map((cell) => (
          <div key={cell.label} className={`pull-cell tone-${cell.tone}`}>
            <span className="pull-cell-label"><Dot tone={cell.tone} />{cell.label}</span>
            <span className="pull-cell-value">{cell.value}</span>
            <span className="pull-cell-sub" title={cell.sub}>{cell.sub}</span>
          </div>
        ))}
      </div>
      {pull.quiz !== null && pull.item !== null && <div className="pull-quiz"><QuizPanel item={pull.item} quiz={pull.quiz} /></div>}
      {review !== null && (review.cannot.length > 0 || review.waiting.length > 0) && <Reviewers review={review} pr={pull.number} />}
      <footer className="pull-foot">
        {blocked === null ? <ActionButton kind="pr.merge" args={{ pr: String(pull.number) }} label="Merge" primary={true} /> : <span className="muted">{blocked}</span>}
        {!pull.draft && <AskReview pr={pull.number} reviewers={snapshot.project.reviewers} />}
      </footer>
    </section>
  );
}

/** The reviewers the flow asked by a mention: who has not answered, and who replied it cannot review here, with what it said. */
function Reviewers({ review, pr }: { review: PullReview; pr: number }) {
  const silent = review.waiting.filter((reviewer) => !review.cannot.some((entry) => entry.reviewer === reviewer));
  return (
    <ul className="pull-reviewers" aria-label="Reviewers">
      {silent.map((reviewer) => (
        <li key={reviewer}><Dot tone="running" /><span className="strong">{reviewer}</span><span className="muted">asked, has not answered yet</span></li>
      ))}
      {review.cannot.map((entry) => (
        <li key={entry.reviewer} className="pull-cannot">
          <Dot tone="needs-you" /><span className="strong">{entry.reviewer}</span>
          <span><span className="muted">cannot review #{pr} here. It replied: </span><q>{entry.said}</q></span>
          <span className="muted pull-cannot-help">The PR waits without that review. Set {entry.reviewer} up for this repository, or drop it from reviews.reviewers, then merge or ask again.</span>
        </li>
      ))}
    </ul>
  );
}

/** The fallback table from items; it renders any list of rows, whichever source built them. */
export function PullRequestTable({ rows, pages }: { rows: PullRequestRow[]; pages: ItemPages }) {
  if (rows.length === 0) return <Empty>No item has a pull request.</Empty>;
  return (
    <table className="table">
      <thead><tr><th>Item</th><th>Title</th><th>PR</th><th>State</th><th>Worktree</th></tr></thead>
      <tbody>
        {rows.map((row) => (
          <tr key={`${row.item}:${row.pr}`}>
            <td><ItemLink id={row.item} pages={pages} /></td>
            <td className="strong">{row.title}</td>
            <td><ExternalLink url={row.url} className="mono">{row.pr}</ExternalLink></td>
            <td><Chip tone={itemTone(row.state)}>{row.state}</Chip></td>
            <td className="mono">{row.worktree ?? '—'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
