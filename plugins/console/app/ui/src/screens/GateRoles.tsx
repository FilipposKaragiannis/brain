import type { Gate } from '../../../daemon/src/snapshot.ts';
import { Markdown } from '../Markdown.tsx';

/** One role of a gate as a chip: what it is, then who or what. */
type Role = { name: string; value: string };

/**
 * Who raised the gate, who carries the answer out, and what it waits on when the health job
 * clears it by itself; nothing for a gate recorded before these were kept.
 */
export function GateRoles({ gate }: { gate: Gate }) {
  const roles = [
    gate.raisedBy === null ? null : { name: 'raised by', value: gate.raisedBy },
    gate.answeredBy === null ? null : { name: 'answered by', value: gate.answeredBy },
    gate.condition === null ? null : { name: 'waits on', value: gate.condition },
  ].filter((role): role is Role => role !== null);
  if (roles.length === 0) return null;
  return (
    <div className="gate-roles">
      {roles.map((role) => <span key={role.name} className="role-chip"><span className="role-name">{role.name}</span> {role.value}</span>)}
    </div>
  );
}

/** The exact clear command the gate's footer gives, for a gate that offers no option buttons. */
export function GateFooter({ gate }: { gate: Gate }) {
  if (gate.options.length > 0 || gate.footer === null) return null;
  return <Markdown className="gate-footer" text={gate.footer} />;
}

/** On a gate with twins: the items one answer clears, all asking the same question under one parent. */
export function TwinNote({ gate, twins }: { gate: Gate; twins: Gate[] }) {
  if (twins.length === 0) return null;
  const items = [gate, ...twins].map((each) => each.item);
  return (
    <p className="gate-twins-note">
      This answer clears {items.length} items that ask the same question under one parent: <span className="mono">{items.join(', ')}</span>. Each gets the same answer.
    </p>
  );
}

/** What a twin row says in the list: how many items its one answer clears. */
export function twinCount(twins: Gate[]): string | null {
  return twins.length === 0 ? null : `answers ${twins.length + 1} items`;
}
