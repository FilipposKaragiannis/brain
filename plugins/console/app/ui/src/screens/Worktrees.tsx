import type { ProcessInfo, Snapshot, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, formatDuration, useLiveSeconds } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import { worktreeTone } from '../status.ts';
import { ActionButton, Chip, Empty, Flags, Module, SourceFreshness, TerminalButton } from '../ui.tsx';
import { WORDS } from '../words.ts';

const COLUMNS = 11;

/** The pool first, then the worktrees outside it under their own heading, then what the columns mean. */
export function Worktrees({ snapshot }: { snapshot: Snapshot }) {
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  const outside = snapshot.worktrees.filter((worktree) => worktree.role !== 'pool');
  return (
    <div className="screen">
      <Module className="worktrees" title="Worktrees" aside={<ActionButton kind="steward.health" args={{}} label="Health" primary={false} />}
        footer={<><SourceFreshness name="git" freshness={snapshot.sources.git} /><SourceFreshness name="processes" freshness={snapshot.sources.processes} /></>}>
        {snapshot.worktrees.length === 0 ? <Empty>No worktree found.</Empty> : (
          <>
            <WorktreeTable worktrees={pool} snapshot={snapshot} label="Pool" />
            {outside.length > 0 && (
              <section className="worktree-group" aria-labelledby="outside-heading">
                <h3 id="outside-heading" className="group-head">Outside the pool</h3>
                <p className="module-help">{WORDS.outside}</p>
                <WorktreeTable worktrees={outside} snapshot={snapshot} label="Outside the pool" />
              </section>
            )}
            <p className="legend"><strong>Dirty</strong> {WORDS.dirty} <strong>Agents</strong> {WORDS.agents} <strong>Sessions</strong> {WORDS.sessions}</p>
          </>
        )}
      </Module>
    </div>
  );
}

function WorktreeTable({ worktrees, snapshot, label }: { worktrees: Worktree[]; snapshot: Snapshot; label: string }) {
  return (
    <div className="scroll">
      <table className="table" aria-label={label}>
        <thead>
          <tr>
            <th>Worktree</th><th>State</th><th>Flags</th><th>Branch</th><th title="Commits ahead of and behind the base">Ahead / behind</th>
            <th title={WORDS.dirty}>Dirty</th><th>Claim age</th><th>Item</th>
            <th title={WORDS.agents}>Agents</th><th title={WORDS.sessions}>Sessions</th><th />
          </tr>
        </thead>
        {worktrees.map((worktree) => <WorktreeRows key={worktree.name} worktree={worktree} snapshot={snapshot} />)}
      </table>
    </div>
  );
}

function WorktreeRows({ worktree, snapshot }: { worktree: Worktree; snapshot: Snapshot }) {
  const note = worktreeNote(worktree, snapshot);
  return (
    <tbody className={worktree.state === 'stale' ? 'worktree-rows hatched' : 'worktree-rows'}>
      <tr>
        <td className="mono strong nowrap" title={worktree.path}>{worktree.name}</td>
        <td><Chip tone={worktreeTone(worktree.state)}>{worktree.state}</Chip></td>
        <td><Flags flags={worktree.flags} /></td>
        <td className="mono clip" title={worktree.branch ?? ''}>{worktree.branch ?? '—'}</td>
        <td className="mono">{worktree.aheadOfBase ?? '—'} / {worktree.behindBase ?? '—'}</td>
        <td className="mono">{worktree.dirtyFiles ?? '—'}</td>
        <td className="mono"><Age seconds={worktree.claimAgeSeconds} takenAt={snapshot.takenAt} /></td>
        <td className="item-cell">
          {worktree.item === null ? '—' : <ItemLink id={worktree.item} pages={snapshot} />}
          {worktree.itemTitle !== null && <span className="item-title clip" title={worktree.itemTitle}>{worktree.itemTitle}</span>}
        </td>
        <td><Processes processes={worktree.agents} takenAt={snapshot.takenAt} /></td>
        <td><Processes processes={worktree.sessions} takenAt={snapshot.takenAt} /></td>
        <td className="buttons">
          <TerminalButton path={worktree.path} />
          {worktree.role === 'pool' && worktree.claim !== null && <ActionButton kind="worktree.release" args={{ target: worktree.name }} label="Release" primary={false} />}
        </td>
      </tr>
      {note !== null && <tr className="note-row"><td colSpan={COLUMNS}>{note}</td></tr>}
    </tbody>
  );
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
