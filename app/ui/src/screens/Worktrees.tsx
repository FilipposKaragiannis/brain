import type { Snapshot, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age } from '../clock.tsx';
import { worktreeTone } from '../status.ts';
import { ActionButton, Chip, Flags, Module, SourceFreshness } from '../ui.tsx';

export function Worktrees({ snapshot }: { snapshot: Snapshot }) {
  return (
    <div className="screen">
      <Module className="worktrees" title="Worktrees" aside={<ActionButton kind="steward.health" args={{}} label="Health" primary={false} />}
        footer={<><SourceFreshness name="git" freshness={snapshot.sources.git} /><SourceFreshness name="processes" freshness={snapshot.sources.processes} /></>}>
        <div className="scroll">
          <table className="table">
            <thead>
              <tr><th>Worktree</th><th>State</th><th>Flags</th><th>Branch</th><th>Ahead / behind</th><th>Dirty</th><th>Claim age</th><th>Item</th><th>Agents</th><th>Sessions</th><th /></tr>
            </thead>
            <tbody>{snapshot.worktrees.map((worktree) => <WorktreeRow key={worktree.name} worktree={worktree} takenAt={snapshot.takenAt} />)}</tbody>
          </table>
        </div>
      </Module>
    </div>
  );
}

function WorktreeRow({ worktree, takenAt }: { worktree: Worktree; takenAt: string }) {
  return (
    <tr className={worktree.state === 'stale' ? 'hatched' : ''}>
      <td className="mono strong" title={worktree.path}>{worktree.name}</td>
      <td><Chip tone={worktreeTone(worktree.state)}>{worktree.state}</Chip></td>
      <td><Flags flags={worktree.flags} /></td>
      <td className="mono clip" title={worktree.branch ?? ''}>{worktree.branch ?? '—'}</td>
      <td className="mono">{worktree.aheadOfBase ?? '—'} / {worktree.behindBase ?? '—'}</td>
      <td className="mono">{worktree.dirtyFiles ?? '—'}</td>
      <td className="mono"><Age seconds={worktree.claimAgeSeconds} takenAt={takenAt} /></td>
      <td className="mono">{worktree.item ?? '—'}</td>
      <td className="mono">{worktree.agentPids.join(', ') || '—'}</td>
      <td className="mono">{worktree.sessionPids.join(', ') || '—'}</td>
      <td>{worktree.role === 'pool' && worktree.claim !== null && <ActionButton kind="worktree.release" args={{ target: worktree.name }} label="Release" primary={false} />}</td>
    </tr>
  );
}
