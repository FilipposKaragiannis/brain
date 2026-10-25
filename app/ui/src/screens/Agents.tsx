import type { Agent, EndedAgent, Job, Snapshot } from '../../../daemon/src/snapshot.ts';
import { Age, clockTime } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { jobTone } from '../status.ts';
import { Transcript } from '../Transcript.tsx';
import { ActionButton, Chip, Empty, Module, SessionButton, SourceFreshness, TerminalButton } from '../ui.tsx';

export function Agents({ snapshot }: { snapshot: Snapshot }) {
  return (
    <div className="screen">
      <Module className="agents" title="Agents" aside={<span className="muted">{snapshot.agents.length} processes</span>} footer={<SourceFreshness name="processes" freshness={snapshot.sources.processes} />}>
        {snapshot.agents.length === 0 ? <Empty>No agent is running.</Empty> : (
          <div className="scroll">
            <table className="table">
              <thead><tr><th>Kind</th><th>Pid</th><th>Host</th><th>Worktree</th><th>Item</th><th>Elapsed</th><th>Command</th><th /></tr></thead>
              {snapshot.agents.map((agent) => <AgentRows key={agent.pid} agent={agent} projectId={snapshot.project.id} takenAt={snapshot.takenAt} pages={snapshot} />)}
            </table>
          </div>
        )}
      </Module>
      {snapshot.ended.length > 0 && (
        <Module className="ended" title="Ended in the last day" aside={<span className="muted">{snapshot.ended.length} with a session to resume</span>} footer={<SourceFreshness name="processes" freshness={snapshot.sources.processes} />}>
          <div className="scroll">
            <table className="table" aria-label="Ended agents and sessions">
              <thead><tr><th>Kind</th><th>Pid</th><th>Host</th><th>Worktree</th><th>Item</th><th>Ended</th><th>Command</th><th /></tr></thead>
              {snapshot.ended.map((agent) => <EndedRows key={`${agent.pid}-${agent.endedAt}`} agent={agent} projectId={snapshot.project.id} takenAt={snapshot.takenAt} pages={snapshot} />)}
            </table>
          </div>
        </Module>
      )}
      <Module className="jobs" title="Jobs" aside={<span className="muted">{snapshot.jobs.length} jobs</span>} footer={<SourceFreshness name="jobs" freshness={snapshot.sources.jobs} />}>
        {snapshot.jobs.length === 0 ? <Empty>No jobs installed.</Empty> : (
          <div className="scroll">
            <table className="table">
              <thead><tr><th>Job</th><th>State</th><th>Schedule</th><th>Last run</th><th>Next</th><th>This week</th><th /></tr></thead>
              <tbody>{snapshot.jobs.map((job) => <JobRow key={job.name} job={job} root={snapshot.project.root} />)}</tbody>
            </table>
          </div>
        )}
      </Module>
    </div>
  );
}

const AGENT_COLUMNS = 8;

/** One agent or session: its row with Open session (when its transcript was found) and Open in Terminal, and its transcript folded under it. */
function AgentRows({ agent, projectId, takenAt, pages }: { agent: Agent; projectId: string; takenAt: string; pages: ItemPages }) {
  return (
    <tbody>
      <AgentRow agent={agent} takenAt={takenAt} pages={pages} />
      {agent.session?.host === 'claude' && <tr className="note-row"><td colSpan={AGENT_COLUMNS}><Transcript projectId={projectId} pid={agent.pid} takenAt={takenAt} /></td></tr>}
    </tbody>
  );
}

function EndedRows({ agent, projectId, takenAt, pages }: { agent: EndedAgent; projectId: string; takenAt: string; pages: ItemPages }) {
  return (
    <tbody>
      <tr>
        <td><Chip tone="quiet">{agent.kind}</Chip></td>
        <td className="mono">{agent.pid}</td>
        <td>{agent.host}</td>
        <td className="mono">{agent.worktree ?? '—'}</td>
        <td>{agent.item === null ? '—' : <ItemLink id={agent.item} pages={pages} />}</td>
        <td className="mono">{clockTime(agent.endedAt)}</td>
        <td className="mono clip" title={agent.command}>{agent.command}</td>
        <td className="buttons" title={agent.cwd}>
          {agent.session !== null && <SessionButton path={agent.cwd} pid={agent.pid} alive={false} />}
          <TerminalButton path={agent.cwd} />
        </td>
      </tr>
      {agent.session?.host === 'claude' && <tr className="note-row"><td colSpan={AGENT_COLUMNS}><Transcript projectId={projectId} pid={agent.pid} takenAt={takenAt} /></td></tr>}
    </tbody>
  );
}

function AgentRow({ agent, takenAt, pages }: { agent: Agent; takenAt: string; pages: ItemPages }) {
  return (
    <tr>
      <td><Chip tone={agent.kind === 'agent' ? 'running' : 'quiet'}>{agent.kind}</Chip></td>
      <td className="mono">{agent.pid}</td>
      <td>{agent.host}</td>
      <td className="mono">{agent.worktree ?? '—'}</td>
      <td>{agent.item === null ? '—' : <ItemLink id={agent.item} pages={pages} />}</td>
      <td className="mono strong"><Age seconds={agent.elapsedSeconds} takenAt={takenAt} /></td>
      <td className="mono clip" title={agent.command}>{agent.command}</td>
      <td className="buttons" title={agent.cwd}>
        {agent.session !== null && <SessionButton path={agent.cwd} pid={agent.pid} alive />}
        <TerminalButton path={agent.cwd} />
      </td>
    </tr>
  );
}

function JobRow({ job, root }: { job: Job; root: string }) {
  const args = { job: job.name };
  return (
    <tr>
      <td className="strong">{job.name}{job.args !== '' && <span className="muted mono"> {job.args}</span>}</td>
      <td><Chip tone={jobTone(job)}>{job.state}</Chip></td>
      <td>{job.schedule}</td>
      <td className="clip" title={job.last?.result ?? ''}>{job.last === null ? '—' : `${clockTime(job.last.at)} · ${job.last.outcome} · ${job.last.result}`}</td>
      <td>{job.next}</td>
      <td className="mono">{job.runsThisWeek} runs{job.failedThisWeek > 0 ? `, ${job.failedThisWeek} failed` : ''}</td>
      <td className="buttons">
        <ActionButton kind="job.run" args={args} label="Run" primary />
        <ActionButton kind="job.stop" args={args} label="Stop" primary={false} />
        {job.paused
          ? <ActionButton kind="job.resume" args={args} label="Resume" primary={false} />
          : <ActionButton kind="job.pause" args={args} label="Pause" primary={false} />}
        <TerminalButton path={root} job={job.name} />
      </td>
    </tr>
  );
}
