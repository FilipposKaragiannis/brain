import type { MergedPull, PullRequest, PullReview, Snapshot } from '../../../daemon/src/snapshot.ts';
import { AskReview } from '../askReview.tsx';
import { Age, clockTime, formatDuration } from '../clock.tsx';
import { ExternalLink, ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { autoMergeOffered, checkRows, forceMergeOffered, healthCells, mergeBlockedReason, pullRowsFromItems, pullTimeline, SHORT_SHA } from '../pulls.ts';
import type { CheckRow, PullRequestRow } from '../pulls.ts';
import { QuizPanel } from '../Quiz.tsx';
import { itemTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { ActionButton, Chip, Dot, Empty, Module, SourceFreshness, useActionsView } from '../ui.tsx';

/** The flow job whose pass on one item's PR merges the base in first when the PR conflicts, and fixes its failing checks. */
const COMMENTS_JOB = 'comments';
const MILLISECONDS_PER_SECOND = 1000;
/** What a check row's mark and tone are, by its outcome. */
const CHECK_MARK: Record<CheckRow['outcome'], { mark: string; tone: Tone }> = {
  failed: { mark: '✕', tone: 'failing' }, pending: { mark: '•', tone: 'running' }, passed: { mark: '✓', tone: 'ready' },
};
/** What Force merge does, on its title: gh's admin merge, past what branch protection requires. */
const FORCE_MERGE_TITLE = 'Merges with gh pr merge --admin, past the checks and rules GitHub requires';

/**
 * Open pull requests from the daemon's `pulls` source, one card each: where it stands, its
 * health, its checks, its reviewers, what happened to it today and the merge; then the pulls
 * merged today. Until that source has been read once, or on a project it does not apply to, the
 * items that carry a PR stand in as a table.
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
  const merged = snapshot.mergedToday.length;
  return (
    <div className="screen">
      <div className="pulls-summary">
        <p aria-label="Summary">
          <span>{snapshot.pulls.length} open{inReview > 0 ? ` · ${inReview} in review` : ''}{mergeable > 0 ? ` · ${mergeable} ready to merge` : ''} · {merged} merged today</span>
          <SourceFreshness name="pulls" freshness={snapshot.sources.pulls} />
        </p>
        <RunCommentsJob snapshot={snapshot} />
      </div>
      {snapshot.pulls.length === 0
        ? <Module className="pulls" title="Pull requests" aside={null} footer={null}><Empty>No open pull request.</Empty></Module>
        : snapshot.pulls.map((pull) => <PullCard key={pull.number} pull={pull} snapshot={snapshot} />)}
      {merged > 0 && <MergedToday merged={snapshot.mergedToday} pages={snapshot} />}
    </div>
  );
}

/** One comments pass over every open PR now: the installed schedule handed to launchd, else a run on the project's host. */
function RunCommentsJob({ snapshot }: { snapshot: Snapshot }) {
  const job = snapshot.jobs.find((entry) => entry.name === COMMENTS_JOB);
  if (job === undefined) return null;
  return job.installed
    ? <ActionButton kind="job.run" args={{ job: COMMENTS_JOB }} label="Run comments job now" primary={false} />
    : <ActionButton kind="job.start" args={{ job: COMMENTS_JOB, host: snapshot.project.jobsHost }} label="Run comments job now" primary={false} />;
}

function PullCard({ pull, snapshot }: { pull: PullRequest; snapshot: Snapshot }) {
  const agent = snapshot.worktrees.find((worktree) => worktree.name === pull.worktree)?.agents[0] ?? null;
  const quizPending = pull.quiz !== null && pull.quiz.result?.passed !== true;
  const blocked = pull.state === 'draft' && quizPending ? 'A draft until you pass the quiz above; then it goes ready for review.' : mergeBlockedReason(pull);
  const review = pull.review;
  return (
    <section className="module pull-card" aria-label={`PR #${pull.number}`}>
      <header className="pull-head">
        <span className="mono pull-number">#{pull.number}</span>
        <h2 className="clip" title={pull.title}>{pull.title}</h2>
        {pull.item !== null && <ItemLink id={pull.item} pages={snapshot} />}
        <span className="chip mono pull-branch">{pull.branch} → {pull.base}</span>
        {agent !== null
          ? <span className="chip tone-running"><Dot tone="running" />agent in {pull.worktree} · <Age seconds={agent.elapsedSeconds} takenAt={snapshot.takenAt} /></span>
          : pull.worktree !== null && <span className="muted mono">{pull.worktree}</span>}
        <ExternalLink url={pull.url} className="pull-open">Open on GitHub</ExternalLink>
      </header>
      <div className="pull-health">
        {healthCells(pull, snapshot.takenAt).map((cell) => (
          <div key={cell.label} className={`pull-cell tone-${cell.tone}`}>
            <span className="pull-cell-label"><Dot tone={cell.tone} />{cell.label}</span>
            <span className="pull-cell-value">{cell.value}</span>
            <span className="pull-cell-sub" title={cell.sub}>{cell.sub}</span>
          </div>
        ))}
      </div>
      {pull.quiz !== null && pull.item !== null && <div className="pull-quiz"><QuizPanel item={pull.item} quiz={pull.quiz} /></div>}
      <div className="pull-body">
        <div className="pull-column">
          <h3>{pull.head === null ? 'Checks' : <>Checks on <span className="mono">{pull.head.slice(0, SHORT_SHA)}</span></>}</h3>
          <Checks rows={checkRows(pull.checkRuns)} />
          <h3>Reviewers</h3>
          {review !== null && (review.cannot.length > 0 || review.waiting.length > 0)
            ? <Reviewers review={review} pr={pull.number} />
            : <p className="muted pull-none">No reviewer the flow asked is waiting.</p>}
        </div>
        <div className="pull-column">
          <h3>Today</h3>
          <Timeline pull={pull} snapshot={snapshot} />
        </div>
      </div>
      <footer className="pull-foot">
        {blocked === null
          ? <ActionButton kind="pr.merge" args={{ pr: String(pull.number) }} label="Merge now" primary={true} />
          : <button type="button" className="button" disabled={true}>Merge now</button>}
        {autoMergeOffered(pull) && <AutoMerge pull={pull} />}
        {pull.state === 'checks-failing' && pull.item !== null && <FixChecks pull={pull} item={pull.item} host={snapshot.project.jobsHost} />}
        {forceMergeOffered(pull) && <span className="pull-force"><ActionButton kind="pr.merge" args={{ pr: String(pull.number), force: 'true' }} label="Force merge" primary={false} title={FORCE_MERGE_TITLE} /></span>}
        {pull.state === 'conflicts' && pull.item !== null && <ResolveConflicts pull={pull} item={pull.item} host={snapshot.project.jobsHost} />}
        {pull.autoMerge !== null
          ? <span className="chip tone-ready pull-armed"><Dot tone="ready" />Armed · {pull.autoMerge.method.toLowerCase()}-merges when its checks and reviews pass</span>
          : blocked !== null && <span className="muted pull-blocked">{blocked}</span>}
        {!pull.draft && <AskReview pr={pull.number} reviewers={snapshot.project.reviewers} />}
      </footer>
    </section>
  );
}

/** Each failed and running check on its own row, with a link to its run; the passed ones folded. */
function Checks({ rows }: { rows: CheckRow[] }) {
  if (rows.length === 0) return <p className="muted pull-none">No check reported.</p>;
  return (
    <ul className="pull-checks" aria-label="Checks">
      {rows.map((row) => (
        <li key={row.name} className={`tone-${CHECK_MARK[row.outcome].tone}`}>
          <span className="pull-check-mark" aria-hidden="true">{CHECK_MARK[row.outcome].mark}</span>
          <span className="strong pull-check-name">{row.url === null ? row.name : <ExternalLink url={row.url} className="">{row.name}</ExternalLink>}</span>
          <span className="muted">{row.sub}</span>
        </li>
      ))}
    </ul>
  );
}

/** What happened to the pull today, newest first, from the flow's events on its item. */
function Timeline({ pull, snapshot }: { pull: PullRequest; snapshot: Snapshot }) {
  const entries = pullTimeline(pull, snapshot.events, snapshot.takenAt);
  if (entries.length === 0) return <p className="muted pull-none">{pull.item === null ? 'No item: the flow logs nothing for this PR.' : `Nothing happened on ${pull.item} today.`}</p>;
  return (
    <ol className="pull-timeline" aria-label="Today">
      {entries.map((entry, index) => (
        <li key={`${entry.at}:${index}`}>
          <span className="mono muted">{clockTime(entry.at)}</span>
          <Dot tone={entry.tone} />
          <span className="pull-timeline-text">{entry.text}</span>
        </li>
      ))}
    </ol>
  );
}

/** Arms GitHub's auto-merge on the pull, which squash-merges it once its checks and reviews pass, or takes it back. */
function AutoMerge({ pull }: { pull: PullRequest }) {
  const pr = String(pull.number);
  return pull.autoMerge === null
    ? <ActionButton kind="pr.auto-merge" args={{ pr }} label="Merge when green" primary={false} title="Turns on GitHub's auto-merge: it squash-merges the PR once its checks and reviews pass" />
    : <ActionButton kind="pr.auto-merge" args={{ pr, off: 'true' }} label="Disarm" primary={false} title="Turns GitHub's auto-merge off for this PR" />;
}

/**
 * Hands a pull whose checks fail to the flow now: one comments pass on its item, which reads the
 * failed runs, fixes the change and pushes, as the scheduled job does once per failing head.
 */
function FixChecks({ pull, item, host }: { pull: PullRequest; item: string; host: string }) {
  const actions = useActionsView();
  const running = actions.busy('job.start', { job: COMMENTS_JOB, item });
  return (
    <span className="pull-fix">
      <ActionButton kind="job.start" args={{ job: COMMENTS_JOB, host, item, pr: String(pull.number) }} label="Ask the agent to fix the checks" primary={false} title={`Runs the comments job on ${item} now; it reads the failed runs and fixes ${pull.branch}`} />
      {running && <span className="muted">A comments pass is running on {item}: it fixes the failing checks.</span>}
    </span>
  );
}

/**
 * Hands a conflicting pull to the flow now: one comments pass on its item, which merges the base
 * in first, as the scheduled job would on its next run. The PR goes along, since an item linked by
 * its task branch alone has no PR recorded for the job to find. While that pass runs the card says so.
 */
function ResolveConflicts({ pull, item, host }: { pull: PullRequest; item: string; host: string }) {
  const actions = useActionsView();
  const running = actions.busy('job.start', { job: COMMENTS_JOB, item });
  return (
    <span className="pull-resolve">
      <ActionButton kind="job.start" args={{ job: COMMENTS_JOB, host, item, pr: String(pull.number) }} label="Resolve conflicts" primary={false} title={`Runs the comments job on ${item} now; it merges ${pull.base} into ${pull.branch} first`} />
      {running && <span className="muted">A comments pass is running on {item}: it merges {pull.base} in first.</span>}
    </span>
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

/** The pulls merged today, newest first: when, how long each was open, and its branch. */
function MergedToday({ merged, pages }: { merged: MergedPull[]; pages: ItemPages }) {
  return (
    <Module className="pulls-merged" title="Merged today" aside={<span className="muted">{merged.length}</span>} footer={null}>
      <ul className="pull-merged" aria-label="Merged today">
        {merged.map((pull) => (
          <li key={pull.number}>
            <span className="pull-check-mark tone-ready" aria-hidden="true">✓</span>
            <ExternalLink url={pull.url} className="mono strong">#{pull.number}</ExternalLink>
            <span className="clip pull-merged-title" title={pull.title}>{pull.item !== null && <><ItemLink id={pull.item} pages={pages} /> </>}{pull.title}</span>
            <span className="mono muted">{clockTime(pull.mergedAt)}</span>
            <span className="muted">open {formatDuration(Math.max(0, Math.floor((Date.parse(pull.mergedAt) - Date.parse(pull.createdAt)) / MILLISECONDS_PER_SECOND)))}</span>
            <span className="mono muted clip">{pull.branch}</span>
          </li>
        ))}
      </ul>
    </Module>
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
