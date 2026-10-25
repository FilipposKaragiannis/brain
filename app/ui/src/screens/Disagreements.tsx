import type { Disagreement, Snapshot } from '../../../daemon/src/snapshot.ts';
import { ItemLink } from '../links.tsx';
import { ActionButton, Chip, Empty, Module, SourceFreshness } from '../ui.tsx';
import { WORDS } from '../words.ts';

/** Where two state stores disagree, what each says, and the button that settles it when there is one. */
export function Disagreements({ snapshot }: { snapshot: Snapshot }) {
  return (
    <Module className="disagreements" title="Disagreements" aside={<span className="muted">{snapshot.disagreements.length} open</span>}
      footer={<><SourceFreshness name="files" freshness={snapshot.sources.files} /><SourceFreshness name="board" freshness={snapshot.sources.board} /></>}>
      <p className="module-help">{WORDS.disagreement}</p>
      {snapshot.disagreements.length === 0 ? <Empty>Every store agrees.</Empty> : (
        <ul className="disagreement-list">
          {snapshot.disagreements.map((disagreement) => <DisagreementRow key={`${disagreement.sources.join('|')}:${disagreement.item ?? ''}:${disagreement.worktree ?? ''}:${disagreement.message}`} disagreement={disagreement} snapshot={snapshot} />)}
        </ul>
      )}
    </Module>
  );
}

function DisagreementRow({ disagreement, snapshot }: { disagreement: Disagreement; snapshot: Snapshot }) {
  return (
    <li className="disagreement">
      <div className="disagreement-head">
        <Chip tone="failing">{disagreement.sources.join(' vs ')}</Chip>
        {disagreement.item !== null && <ItemLink id={disagreement.item} pages={snapshot} />}
        {disagreement.worktree !== null && <span className="mono muted">{disagreement.worktree}</span>}
        <span className="strong">{disagreement.message}</span>
      </div>
      <p className="disagreement-explain">{disagreement.explain}</p>
      {disagreement.action !== null && <ActionButton kind={disagreement.action.kind} args={disagreement.action.args} label={disagreement.action.label} primary={false} />}
    </li>
  );
}
