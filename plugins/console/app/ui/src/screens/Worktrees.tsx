import { useState } from 'react';
import type { ActionRecord, ProcessInfo, Snapshot, SyncConflict, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, formatDuration, useLiveSeconds } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import { routeHash } from '../route.ts';
import { worktreeTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { ActionButton, Chip, Dot, Empty, Flags, Module, SourceFreshness, TerminalButton, useActionsView } from '../ui.tsx';
import { WORDS } from '../words.ts';

/** How many commits behind the base fill a card's behind bar; a stale branch passes 20. */
const FULL_BEHIND = 40;
const FAR_BEHIND = 20;
/** How many conflicting files a card lists before "Show all". */
export const CONFLICT_FILES_SHOWN = 5;
export const HAND_TO_THE_FLOW = 'Hand to the flow';
export const HAND_TO_THE_FLOW_TITLE = "Writes the sync note and starts the item's run. The flow's sync step merges, resolves what it can, and raises an escalation gate if a choice is yours.";
export const RUN_GOING_SYNC_FIRST = 'A run is going; the sync step runs first when it starts';
export const HANDING_OFF = 'Handing off to the flow: the sync note shows here once it is read';
export const RESERVE_TITLE = 'Takes this worktree for your own work, under your git name. The flow leaves it alone until you release it.';
export const RELEASE_RESERVED_TITLE = 'Gives your reservation back: the worktree returns to the pool and the flow may claim it again.';
export const SWEEP_TITLE = 'Frees the worktrees whose PR merged or whose item closed, and clears their merge gates.';

type Filter = 'all' | 'running' | 'needs-you' | 'stale' | 'claimed' | 'free';
const FILTERS: { filter: Filter; label: string; tone: Tone }[] = [
  { filter: 'all', label: 'All', tone: 'quiet' },
  { filter: 'running', label: 'Running', tone: 'running' },
  { filter: 'needs-you', label: 'Needs you', tone: 'needs-you' },
  { filter: 'stale', label: 'Stale', tone: 'stale' },
  { filter: 'claimed', label: 'Claimed', tone: 'quiet' },
  { filter: 'free', label: 'Free', tone: 'quiet' },
];

/** The pool as cards with a filter by state, then the worktrees outside it under their own heading. */
export function Worktrees({ snapshot }: { snapshot: Snapshot }) {
  const [filter, setFilter] = useState<Filter>('all');
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  const outside = snapshot.worktrees.filter((worktree) => worktree.role !== 'pool');
  const shown = pool.filter((worktree) => filter === 'all' || worktree.state === filter);
  const count = (each: Filter): number => pool.filter((worktree) => each === 'all' || worktree.state === each).length;
  return (
    <div className="screen">
      <div className="worktree-tools">
        <div className="filter-chips" role="group" aria-label="Show">
          {FILTERS.filter((each) => each.filter !== 'claimed' || count('claimed') > 0).map((each) => (
            <button key={each.filter} type="button" className={`filter-chip tone-${each.tone}`} aria-pressed={filter === each.filter} onClick={() => setFilter(each.filter)}>
              {each.filter !== 'all' && <Dot tone={each.tone} />}{each.label} <span className="filter-count">{count(each.filter)}</span>
            </button>
          ))}
        </div>
        <span className="worktree-base muted">{pool.length} in the pool{snapshot.project.poolMax !== null && snapshot.project.poolMax > pool.length ? `, grows to ${snapshot.project.poolMax}` : ''} · base {snapshot.project.base}</span>
        <ActionButton kind="steward.health" args={{}} label="Run health" primary={false} />
        <ActionButton kind="steward.sweep" args={{}} label="Sweep" primary={false} title={SWEEP_TITLE} />
      </div>
      {snapshot.worktrees.length === 0 ? <Empty>No worktree found.</Empty> : (
        <>
          <section className="worktree-cards" aria-label="Pool">
            {shown.length === 0 ? <Empty>No pool worktree is {filter.replace('-', ' ')}.</Empty> : shown.map((worktree) => <WorktreeCard key={worktree.name} worktree={worktree} snapshot={snapshot} />)}
          </section>
          {outside.length > 0 && (
            <Module className="worktrees-outside" title={<>Outside the pool <span className="muted">{WORDS.outside}</span></>} aside={null}
              footer={<><SourceFreshness name="git" freshness={snapshot.sources.git} /><SourceFreshness name="processes" freshness={snapshot.sources.processes} /></>}>
              <table className="table outside-table" aria-label="Outside the pool">
                <tbody>
                  {outside.map((worktree) => (
                    <tr key={worktree.name}>
                      <td className="strong nowrap" title={worktree.path}>{worktree.name}</td>
                      <td className="mono clip" title={worktree.branch ?? ''}>{worktree.branch ?? '—'}{worktree.head !== null && ` · ${worktree.head.slice(0, 8)}`}</td>
                      <td className="muted">{outsideNote(worktree, snapshot)}</td>
                      <td className="buttons"><TerminalButton path={worktree.path} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </Module>
          )}
        </>
      )}
    </div>
  );
}

function outsideNote(worktree: Worktree, snapshot: Snapshot): string {
  if (worktree.role === 'main') return 'the flow home, jobs run here';
  const parts: string[] = [];
  if (worktree.aheadOfBase !== null && worktree.aheadOfBase > 0) parts.push(`${worktree.aheadOfBase} ahead of ${snapshot.project.base}`);
  if (worktree.dirtyFiles !== null && worktree.dirtyFiles > 0) parts.push(`${worktree.dirtyFiles} uncommitted`);
  const people = worktree.sessions.length + worktree.agents.length;
  if (people > 0) parts.push(`${people} ${people === 1 ? 'session' : 'sessions'} here`);
  return parts.length === 0 ? 'not claimed by the flow' : parts.join(' · ');
}

/**
 * One pool worktree: its state, the item and branch, the step, its tree and how far behind the
 * base it is, who works in it, why it is stale and the way out, and the buttons that act on it.
 */
function WorktreeCard({ worktree, snapshot }: { worktree: Worktree; snapshot: Snapshot }) {
  const tone = worktreeTone(worktree.state);
  const note = worktreeNote(worktree, snapshot);
  const { records } = useActionsView();
  const open = openConflict(records, worktree, snapshot.sources.files.at);
  const pull = worktree.item === null ? null : snapshot.pulls.find((each) => each.item === worktree.item) ?? null;
  const branch = [worktree.branch ?? 'detached', worktree.head?.slice(0, 8) ?? null, pull === null ? null : `PR #${pull.number}`].filter((part) => part !== null).join(' · ');
  const behind = worktree.behindBase ?? 0;
  const behindTone = behind >= FAR_BEHIND ? 'stale' : behind > 0 ? 'needs-you' : 'quiet';
  return (
    <article className={`worktree-card tone-${tone}${worktree.state === 'stale' ? ' hatched' : ''}`} aria-label={worktree.name}>
      <header className="worktree-card-head">
        <span className="mono strong worktree-name" title={worktree.path}>{worktree.name}</span>
        <Chip tone={tone}>{worktree.state}</Chip>
        <Flags flags={worktree.flags} />
        <span className="worktree-right mono"><CardRight worktree={worktree} snapshot={snapshot} /></span>
      </header>
      <div className="worktree-card-what">
        {worktree.item === null
          ? <span className="muted">{worktree.claim?.reserved ? `reserved by ${worktree.claim.reserved}` : worktree.state === 'free' ? 'free' : 'no item'}</span>
          : <span className="worktree-item"><ItemLink id={worktree.item} pages={snapshot} />{worktree.itemTitle !== null && <span className="strong clip-line" title={worktree.itemTitle}>{worktree.itemTitle}</span>}</span>}
        <div className="mono muted clip-line" title={branch}>{branch}</div>
      </div>
      <dl className="worktree-stats">
        <div><dt>step</dt><dd>{worktree.claim?.step ?? '—'}</dd></div>
        <div title={WORDS.dirty}><dt>tree</dt><dd className={worktree.dirtyFiles !== null && worktree.dirtyFiles > 0 ? 'tone-needs-you tone-text' : undefined}>{worktree.dirtyFiles === null ? '—' : worktree.dirtyFiles === 0 ? 'clean' : `${worktree.dirtyFiles} ${worktree.dirtyFiles === 1 ? 'file' : 'files'}`}</dd></div>
        <div title={`Commits behind ${worktree.claim?.base || snapshot.project.base}; ahead ${worktree.aheadOfBase ?? '—'}`}>
          <dt><span>behind {worktree.claim?.base || snapshot.project.base}</span><span className={`tone-${behindTone} tone-text`}>{worktree.behindBase ?? '—'}</span></dt>
          <dd><span className={`behind-bar tone-${behindTone}`}><span style={{ width: `${Math.min(behind / FULL_BEHIND, 1) * 100}%` }} /></span></dd>
        </div>
      </dl>
      {(worktree.agents.length > 0 || worktree.sessions.length > 0) && (
        <div className="worktree-who">
          {worktree.agents.length > 0 && <span title={WORDS.agents}><span className="muted">agents</span> <Processes processes={worktree.agents} takenAt={snapshot.takenAt} /></span>}
          {worktree.sessions.length > 0 && <span title={WORDS.sessions}><span className="muted">sessions</span> <Processes processes={worktree.sessions} takenAt={snapshot.takenAt} /></span>}
        </div>
      )}
      {note !== null && <div className="worktree-note">{note}</div>}
      {(open !== null || worktree.syncPending !== null) && <div className="worktree-note"><SyncNote worktree={worktree} snapshot={snapshot} open={open} /></div>}
      <footer className="buttons worktree-card-foot">
        <PrimaryLink worktree={worktree} snapshot={snapshot} />
        <TerminalButton path={worktree.path} />
        <HoldButton worktree={worktree} />
      </footer>
      {worktree.state === 'running' && <div className="worktree-stripes run-stripes" aria-hidden="true" />}
    </article>
  );
}

/**
 * Reserve on a free card, Release on a claimed or reserved one, in the same place. Each names its
 * card's worktree, so its running and outcome states show on that card only.
 */
function HoldButton({ worktree }: { worktree: Worktree }) {
  const args = { target: worktree.name };
  if (worktree.claim?.reserved) return <ActionButton kind="worktree.release" args={args} label="Release" primary={false} title={RELEASE_RESERVED_TITLE} />;
  if (worktree.claim !== null) return <ActionButton kind="worktree.release" args={args} label="Release" primary={false} />;
  if (worktree.state === 'free') return <ActionButton kind="worktree.reserve" args={args} label="Reserve" primary={false} title={RESERVE_TITLE} />;
  return null;
}

/** What the card's top right says: how long a run has gone, how long the claim has waited, or the base a free worktree sits at. */
function CardRight({ worktree, snapshot }: { worktree: Worktree; snapshot: Snapshot }) {
  const agent = worktree.agents[0];
  if (worktree.state === 'running' && agent !== undefined) return <Age seconds={agent.elapsedSeconds} takenAt={snapshot.takenAt} />;
  if (worktree.claimAgeSeconds !== null) return <Age seconds={worktree.claimAgeSeconds} takenAt={snapshot.takenAt} />;
  return <>{snapshot.project.base}</>;
}

/** The screen where a busy worktree is settled: its run on Agents, its gate on Gates. */
function PrimaryLink({ worktree, snapshot }: { worktree: Worktree; snapshot: Snapshot }) {
  const projectId = snapshot.project.id;
  if (worktree.state === 'running') return <a className="button primary" href={routeHash({ projectId, screen: 'agents', detail: null })}>Watch</a>;
  if (worktree.state === 'needs-you' && worktree.item !== null) return <a className="button primary" href={routeHash({ projectId, screen: 'gates', detail: worktree.item })}>Decide</a>;
  return null;
}

function worktreeNote(worktree: Worktree, snapshot: Snapshot) {
  if (worktree.state === 'stale') {
    return <><span className="stale-reason">Stale: {worktree.staleReason ?? 'see the flags'}.</span> <span className="call-to-action"><StaleWayOut worktree={worktree} snapshot={snapshot} /></span></>;
  }
  const session = worktree.sessions[0];
  if (worktree.state === 'free' && session !== undefined) return <FreeWithSession session={session} count={worktree.sessions.length} takenAt={snapshot.takenAt} />;
  return null;
}

/**
 * Whether the console can merge the base in for you: the same checks the daemon makes before a
 * `worktree.sync` (claimed, nothing uncommitted, no run record for its item, no agent in it).
 */
export function canSync(worktree: Worktree, snapshot: Snapshot): boolean {
  const item = worktree.claim?.item ?? null;
  return worktree.role === 'pool' && item !== null && worktree.dirtyFiles === 0 && worktree.agents.length === 0 && !snapshot.runs.some((run) => run.item === item);
}

/** The way out of a stale worktree: Merge <base> in as a button when the console can do it, else in words. */
function StaleWayOut({ worktree, snapshot }: { worktree: Worktree; snapshot: Snapshot }) {
  const base = worktree.claim?.base || snapshot.project.base;
  const behind = worktree.flags.includes('stale-branch');
  const idle = worktree.flags.includes('idle');
  if (behind && canSync(worktree, snapshot)) {
    return <><ActionButton kind="worktree.sync" args={{ target: worktree.name }} label={`Merge ${base} in`} primary />{idle ? " and run the item's next step, or release the worktree." : ', or release the worktree.'}</>;
  }
  return <>{staleWayOut(behind, idle, base)}</>;
}

function staleWayOut(behind: boolean, idle: boolean, base: string): string {
  const steps: string[] = [];
  if (behind) steps.push(`Merge ${base} in`);
  if (idle) steps.push(steps.length === 0 ? "Run the item's next step" : "run the item's next step");
  if (steps.length === 0) return 'Release the worktree, or look at why it stopped.';
  return `${steps.join(' and ')}, or release the worktree.`;
}

/** Whether an action names this worktree: by its name or by its claimed item, as a sync target may. */
function namesWorktree(record: ActionRecord, worktree: Worktree): boolean {
  const target = record.args['target'];
  return target === worktree.name || (worktree.item !== null && target === worktree.item);
}

/** A sync conflict still owed, and whether a hand-off of it was accepted but its note not read back yet. */
export type OpenConflict = { conflict: SyncConflict; handingOff: boolean };

/**
 * The conflict the last `worktree.sync` of this worktree ended in, while it is still open. A later
 * sync closes it. So does an accepted hand-off after it, but only once the files source has read
 * the worktree since the hand-off began and found no note (the flow's sync step merged and dropped
 * it); until that read it shows as handing off. Records are newest first.
 */
export function openConflict(records: ActionRecord[], worktree: Worktree, filesReadAt: string | null): OpenConflict | null {
  const syncAt = records.findIndex((record) => record.kind === 'worktree.sync' && namesWorktree(record, worktree));
  const conflict = syncAt < 0 ? null : records[syncAt]!.conflict;
  if (conflict === null) return null;
  const handoff = records.slice(0, syncAt).find((record) => record.kind === 'sync.handoff' && namesWorktree(record, worktree) && record.state !== 'failed' && record.state !== 'rejected');
  if (handoff === undefined || worktree.syncPending !== null) return { conflict, handingOff: false };
  const readSince = filesReadAt !== null && Date.parse(filesReadAt) > Date.parse(handoff.startedAt ?? handoff.requestedAt);
  return readSince ? null : { conflict, handingOff: true };
}

/**
 * The merge the flow still owes the branch: the refs its sync note names, and, after a
 * `worktree.sync` that conflicted, the files and the hand-off to the flow's sync step.
 */
function SyncNote({ worktree, snapshot, open }: { worktree: Worktree; snapshot: Snapshot; open: OpenConflict | null }) {
  const [allFiles, setAllFiles] = useState(false);
  const running = worktree.item !== null && snapshot.runs.some((run) => run.item === worktree.item);
  const pending = worktree.syncPending;
  const conflict = open?.conflict ?? null;
  const files = conflict === null ? [] : allFiles ? conflict.files : conflict.files.slice(0, CONFLICT_FILES_SHOWN);
  return (
    <div className="sync-note">
      {pending !== null && <span className="sync-pending">sync pending: <span className="mono">{pending.join(', ')}</span></span>}
      {conflict !== null && (
        <>
          <span className="sync-conflict">Merging <span className="mono">{conflict.refs[0] ?? 'the base'}</span> conflicts in {conflict.files.length} {conflict.files.length === 1 ? 'file' : 'files'}; the merge was aborted.</span>
          <ul className="conflict-files mono" aria-label="Conflicting files">{files.map((file) => <li key={file}>{file}</li>)}</ul>
          {conflict.files.length > CONFLICT_FILES_SHOWN && (
            <button type="button" className="row-link" onClick={() => setAllFiles((shown) => !shown)}>{allFiles ? 'Show fewer files' : `Show all ${conflict.files.length} files`}</button>
          )}
          <span className="call-to-action">
            {open?.handingOff === true ? HANDING_OFF : running ? (pending !== null ? RUN_GOING_SYNC_FIRST : 'A run is going; hand the merge to the flow once it ends') : <ActionButton kind="sync.handoff" args={{ target: worktree.name, refs: conflict.refs.join('\n') }} label={HAND_TO_THE_FLOW} primary title={HAND_TO_THE_FLOW_TITLE} />}
          </span>
        </>
      )}
    </div>
  );
}

function FreeWithSession({ session, count, takenAt }: { session: ProcessInfo; count: number; takenAt: string }) {
  const elapsed = useLiveSeconds(session.elapsedSeconds, takenAt);
  const others = count > 1 ? ` and ${count - 1} more` : '';
  return <span>Free. A {session.host} session sits here (pid {session.pid}, {formatDuration(elapsed)}){others}.</span>;
}

function Processes({ processes, takenAt }: { processes: ProcessInfo[]; takenAt: string }) {
  if (processes.length === 0) return <span className="muted">—</span>;
  return (
    <ul className="process-list">
      {processes.map((process) => (
        <li key={process.pid} tabIndex={0} title={process.command}><span className="mono">{process.pid}</span> {process.host}<span className="process-age"><Age seconds={process.elapsedSeconds} takenAt={takenAt} /></span><span className="process-command mono">{process.command}</span></li>
      ))}
    </ul>
  );
}
