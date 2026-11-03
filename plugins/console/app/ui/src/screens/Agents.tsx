import { useState } from 'react';
import type { Agent, EndedAgent, PullRequest, Run, Snapshot, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, clockTime, Since } from '../clock.tsx';
import { ExternalLink, ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { routeHash } from '../route.ts';
import { FULL_LINES, RunStream, TAIL_LINES, transcriptSize, useTranscript } from '../Transcript.tsx';
import { ActionButton, Chip, Dot, Empty, Module, SessionButton, SourceFreshness, TerminalButton } from '../ui.tsx';

/**
 * What runs. Flow's own runs are cards with their transcript as a live terminal, and a run record
 * without a process is a card that says what to do; under them the owner's own sessions fold away,
 * then the agents and sessions that ended in the last day. Jobs and their schedules have a page of
 * their own.
 */
export function Agents({ snapshot }: { snapshot: Snapshot }) {
  const runs = snapshot.agents.filter((agent) => agent.kind === 'agent');
  const sessions = snapshot.agents.filter((agent) => agent.kind === 'session');
  const dead = snapshot.runs.filter((run) => !run.alive);
  const live = dead.length + runs.length;
  const jobs = routeHash({ projectId: snapshot.project.id, screen: 'jobs', detail: null });
  return (
    <div className="screen agents-screen">
      <Module className="runs" title="Runs" aside={<span className="muted">{runs.length} running{dead.length > 0 ? ` · ${dead.length} without a process` : ''}</span>} footer={<SourceFreshness name="processes" freshness={snapshot.sources.processes} />}>
        {live === 0 ? <Empty>No flow run is going. Start one on <a href={jobs}>Jobs</a>, with Run once or Run now on a job, or from the board.</Empty> : (
          <div className="run-cards">
            {dead.map((run) => <DeadRunCard key={`${run.item}-${run.worktree}`} run={run} snapshot={snapshot} />)}
            {runs.map((agent, index) => <RunCard key={agent.pid} agent={agent} snapshot={snapshot} startOpen={index === 0} />)}
          </div>
        )}
      </Module>
      <Sessions sessions={sessions} snapshot={snapshot} />
      {snapshot.ended.length > 0 && <Ended snapshot={snapshot} />}
    </div>
  );
}

/**
 * One live flow run: its step and item, where it runs, its PR, and its transcript as a live
 * terminal. It folds to its header, so several runs stay a short list; only the first starts open.
 */
function RunCard({ agent, snapshot, startOpen }: { agent: Agent; snapshot: Snapshot; startOpen: boolean }) {
  const [open, setOpen] = useState(startOpen);
  const [full, setFull] = useState(false);
  const run = runOf(agent, snapshot.runs);
  const pull = pullOf(agent.item, snapshot.pulls);
  const worktree = snapshot.worktrees.find((candidate) => candidate.name === agent.worktree) ?? null;
  const claude = agent.session?.host === 'claude';
  return (
    <article className={open ? 'run-card' : 'run-card folded'} aria-label={`Run ${agent.pid}`}>
      <header className="run-card-head">
        <button type="button" className="fold-toggle" aria-expanded={open} aria-label={open ? `Fold run ${agent.pid}` : `Open run ${agent.pid}`} onClick={() => setOpen((shown) => !shown)}>▸</button>
        <Dot tone="running" />
        <span className="run-card-title">
          <span className="strong">{run?.step ?? 'agent'}</span>
          {agent.item !== null && <> · <ItemLink id={agent.item} pages={snapshot} /></>}
        </span>
        <span className="run-card-tags">
          {agent.worktree !== null && <span className="tag mono">{agent.worktree}</span>}
          <span className="tag">{agent.host}</span>
          {pull !== null && <ExternalLink url={pull.url} className="tag">PR #{pull.number}</ExternalLink>}
        </span>
        <span className="mono strong run-card-age"><Age seconds={agent.elapsedSeconds} takenAt={snapshot.takenAt} /></span>
      </header>
      {open && (
        <>
          {claude ? <ClaudeRun agent={agent} run={run} worktree={worktree} snapshot={snapshot} full={full} /> : (
            <>
              <RunStats run={run} agent={agent} worktree={worktree} transcript={null} />
              <p className="run-card-say">The console reads Claude transcripts only. Open the session to follow this {agent.host} run.</p>
            </>
          )}
          <div className="run-stripes" aria-hidden="true" />
          <footer className="buttons run-card-foot" title={agent.cwd}>
            {claude && <button type="button" className="button" aria-pressed={full} onClick={() => setFull((shown) => !shown)}>{full ? 'Last lines' : 'Full log'}</button>}
            {pull !== null && <ExternalLink url={pull.url} className="button">PR #{pull.number}</ExternalLink>}
            <OpenButton path={agent.cwd} pid={agent.pid} hasSession={agent.session !== null} alive />
            {agent.item !== null && (
              <span className="run-stop">
                <ActionButton kind="run.stop" args={{ item: agent.item }} label="Stop this run" primary={false} title={STOP_HELP} />
              </span>
            )}
          </footer>
        </>
      )}
    </article>
  );
}

export const STOP_HELP = 'Ends this run and clears its record. The worktree keeps its commits and changes, and the item stays at its step for a later run.';

function ClaudeRun({ agent, run, worktree, snapshot, full }: { agent: Agent; run: Run | null; worktree: Worktree | null; snapshot: Snapshot; full: boolean }) {
  const read = useTranscript(snapshot.project.id, agent.pid, snapshot.takenAt, full ? FULL_LINES : TAIL_LINES);
  return (
    <>
      <RunStats run={run} agent={agent} worktree={worktree} transcript={read.kind === 'read' ? read : null} />
      <RunStream read={read} pid={agent.pid} full={full} />
    </>
  );
}

/** When it started, its last commit, how big its transcript is, and its pid. */
function RunStats({ run, agent, worktree, transcript }: { run: Run | null; agent: Agent; worktree: Worktree | null; transcript: { bytes: number; turnCount: number } | null }) {
  return (
    <dl className="run-card-stats">
      <div><dt>Started</dt><dd className="mono">{run?.startedAt == null ? '—' : clockTime(run.startedAt)}</dd></div>
      <div><dt>Last commit</dt><dd className="mono">{worktree?.head == null ? '—' : `${worktree.head.slice(0, 8)}${worktree.lastCommitAt === null ? '' : ` · ${clockTime(worktree.lastCommitAt)}`}`}</dd></div>
      <div><dt>Transcript</dt><dd>{transcript === null ? '—' : `${transcriptSize(transcript.bytes)} · ${transcript.turnCount} turns`}</dd></div>
      <div><dt>Pid</dt><dd className="mono" title={agent.command}>{agent.pid}</dd></div>
    </dl>
  );
}

/** A run record whose process is gone: it crashed, was killed, or the Mac slept through it. */
function DeadRunCard({ run, snapshot }: { run: Run; snapshot: Snapshot }) {
  const path = snapshot.worktrees.find((worktree) => worktree.name === run.worktree)?.path ?? null;
  return (
    <article className="run-card dead" aria-label={`Run record for ${run.item}`}>
      <header className="run-card-head">
        <span className="dot-dashed" aria-hidden="true" />
        <span className="run-card-title"><span className="strong">{run.step}</span> · <ItemLink id={run.item} pages={snapshot} /></span>
        <span className="run-card-tags"><span className="tag mono">{run.worktree}</span><span className="tag">{run.host}</span><span className="tag tag-warn">record, no process</span></span>
        <span className="muted">{run.startedAt === null ? '' : <>since <Since at={run.startedAt} /></>}</span>
      </header>
      <p className="run-card-say">
        This run ended without clearing its record. Resume clears it and starts {run.step} again in {run.worktree}, from the commits and changes already there. The health job does the same on its next run.
      </p>
      <footer className="buttons">
        <ActionButton kind="run.resume" args={{ item: run.item }} label="Resume" primary />
        {path !== null && <TerminalButton path={path} />}
      </footer>
    </article>
  );
}

/** The owner's own sessions, folded: they are not flow's work, but they can be resumed from here. */
function Sessions({ sessions, snapshot }: { sessions: Agent[]; snapshot: Snapshot }) {
  if (sessions.length === 0) return null;
  return (
    <details className="module fold sessions">
      <summary className="module-head"><h2>Your sessions ({sessions.length})</h2><span className="muted">Claude and Codex you started yourself</span></summary>
      <ul className="row-list" aria-label="Your sessions">
        {sessions.map((session) => (
          <li key={session.pid} aria-label={`Session ${session.pid}`}>
            <Dot tone="quiet" />
            <span className="mono">{session.pid}</span>
            <span>{session.host}</span>
            <span className="mono clip" title={session.cwd}>{session.worktree ?? session.cwd}</span>
            <span>{session.item === null ? '' : <ItemLink id={session.item} pages={snapshot} />}</span>
            <span className="mono"><Age seconds={session.elapsedSeconds} takenAt={snapshot.takenAt} /></span>
            <span className="buttons">
              <OpenButton path={session.cwd} pid={session.pid} hasSession={session.session !== null} alive />
            </span>
          </li>
        ))}
      </ul>
    </details>
  );
}

function Ended({ snapshot }: { snapshot: Snapshot }) {
  return (
    <Module className="ended" title="Ended in the last day" aside={<span className="muted">{snapshot.ended.length} with a session to resume</span>} footer={<SourceFreshness name="processes" freshness={snapshot.sources.processes} />}>
      <div className="scroll">
        <table className="table" aria-label="Ended agents and sessions">
          <thead><tr><th>Kind</th><th>Pid</th><th>Host</th><th>Worktree</th><th>Item</th><th>Ended</th><th /></tr></thead>
          <tbody>{snapshot.ended.map((agent) => <EndedRow key={`${agent.pid}-${agent.endedAt}`} agent={agent} pages={snapshot} />)}</tbody>
        </table>
      </div>
    </Module>
  );
}

function EndedRow({ agent, pages }: { agent: EndedAgent; pages: ItemPages }) {
  return (
    <tr>
      <td><Chip tone="quiet">{agent.kind}</Chip></td>
      <td className="mono" title={agent.command}>{agent.pid}</td>
      <td>{agent.host}</td>
      <td className="mono">{agent.worktree ?? '—'}</td>
      <td>{agent.item === null ? '—' : <ItemLink id={agent.item} pages={pages} />}</td>
      <td className="mono">{clockTime(agent.endedAt)}</td>
      <td className="buttons" title={agent.cwd}>
        <OpenButton path={agent.cwd} pid={agent.pid} hasSession={agent.session !== null} alive={false} />
      </td>
    </tr>
  );
}

/**
 * One button to the folder a process works in: Open session when its session can be resumed,
 * which opens a terminal there too, else Open in Terminal. Two buttons to the same folder would
 * leave the owner guessing which one to press.
 */
function OpenButton({ path, pid, hasSession, alive }: { path: string; pid: number; hasSession: boolean; alive: boolean }) {
  return hasSession ? <SessionButton path={path} pid={pid} alive={alive} /> : <TerminalButton path={path} />;
}

/** The run record an agent works for: the one in its worktree, else the one for its item. */
function runOf(agent: Agent, runs: Run[]): Run | null {
  return runs.find((run) => agent.worktree !== null && run.worktree === agent.worktree)
    ?? runs.find((run) => agent.item !== null && run.item === agent.item)
    ?? null;
}

function pullOf(item: string | null, pulls: PullRequest[]): PullRequest | null {
  if (item === null) return null;
  return pulls.find((pull) => pull.item === item) ?? null;
}
