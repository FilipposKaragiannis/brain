import { useCallback, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import type { Agent, EndedAgent, Job, JobRun, JobWorker, PullRequest, Run, Snapshot, StoppedHost, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, clockTime, Since } from '../clock.tsx';
import { JOB_KINDS, newScheduleProblem, ownArgs, pairSpec, scheduleName, scheduleProblem, scheduleSpec, startArgs, startFormFrom, startProblem, whenFrom } from '../jobStart.ts';
import type { ScheduleWhen } from '../jobStart.ts';
import { ExternalLink, ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { routeHash } from '../route.ts';
import { RunFields, useRunForm, WhenFields } from '../scheduleFields.tsx';
import { jobTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { FULL_LINES, RunStream, TAIL_LINES, transcriptSize, useTranscript } from '../Transcript.tsx';
import { ActionButton, Chip, Dot, Empty, Module, SessionButton, SourceFreshness, TerminalButton, useActionsView } from '../ui.tsx';

const EVENTS_SHOWN = 15;

/**
 * What runs and what is scheduled. Flow's own runs are cards with their transcript as a live
 * terminal, and a run record without a process is a card that says what to do; the schedules
 * sit under them, and the owner's own sessions fold away. The side column holds a stopped host
 * first, then the panel that adds a schedule of next or runs it once, then the latest events.
 */
export function Agents({ snapshot }: { snapshot: Snapshot }) {
  const runs = snapshot.agents.filter((agent) => agent.kind === 'agent');
  const sessions = snapshot.agents.filter((agent) => agent.kind === 'session');
  const dead = snapshot.runs.filter((run) => !run.alive);
  const live = dead.length + runs.length;
  return (
    <div className="screen agents-screen">
      <div className="agents-main">
        <Fold className="agents" title="Runs" aside={<span className="muted">{runs.length} running{dead.length > 0 ? ` · ${dead.length} without a process` : ''}</span>} footer={<SourceFreshness name="processes" freshness={snapshot.sources.processes} />}>
          {live === 0 ? <Empty>No flow run is going. Start one from the Run once panel, Run now on a job, or the board.</Empty> : (
            <div className="run-cards">
              {dead.map((run) => <DeadRunCard key={`${run.item}-${run.worktree}`} run={run} snapshot={snapshot} />)}
              {runs.map((agent, index) => <RunCard key={agent.pid} agent={agent} snapshot={snapshot} startOpen={index === 0} />)}
            </div>
          )}
        </Fold>
        <Jobs snapshot={snapshot} />
        <Sessions sessions={sessions} snapshot={snapshot} />
        {snapshot.ended.length > 0 && <Ended snapshot={snapshot} />}
      </div>
      <div className="agents-side">
        {snapshot.stoppedHosts.map((stopped) => <StoppedHostCard key={stopped.host} stopped={stopped} pages={snapshot} />)}
        <StartPanel jobs={snapshot.jobs} jobsHost={snapshot.project.jobsHost} />
        <Events snapshot={snapshot} />
      </div>
    </div>
  );
}

/** A module that folds under its title; it starts open. */
function Fold({ title, aside, footer, children, className }: { title: string; aside: ReactNode; footer: ReactNode; children: ReactNode; className: string }) {
  return (
    <details className={`module fold ${className}`} open>
      <summary className="module-head"><h2>{title}</h2>{aside}</summary>
      <div className="module-body">{children}</div>
      <footer className="module-foot">{footer}</footer>
    </details>
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
            {agent.session !== null && <SessionButton path={agent.cwd} pid={agent.pid} alive />}
            <TerminalButton path={agent.cwd} />
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
              {session.session !== null && <SessionButton path={session.cwd} pid={session.pid} alive />}
              <TerminalButton path={session.cwd} />
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
        {agent.session !== null && <SessionButton path={agent.cwd} pid={agent.pid} alive={false} />}
        <TerminalButton path={agent.cwd} />
      </td>
    </tr>
  );
}

/** A host flow stopped after an error: no job runs on it until the owner clears it. */
function StoppedHostCard({ stopped, pages }: { stopped: StoppedHost; pages: ItemPages }) {
  return (
    <section className="module blocker" aria-label={`${stopped.host} is stopped`}>
      <header className="module-head">
        <h2><Dot tone="failing" />{stopped.host} is stopped</h2>
        <span className="muted">{stopped.at === null ? '' : <Since at={stopped.at} />}</span>
      </header>
      <div className="blocker-body">
        <p><span className="strong">{stopCause(stopped.cause)}</span>{stopped.item !== null && <> on <ItemLink id={stopped.item} pages={pages} /></>}</p>
        {stopped.said !== '' && <pre className="blocker-said">{stopped.said}</pre>}
        <p className="muted">No job runs on {stopped.host} until you clear this. Fix the cause first, such as a usage limit or a login.</p>
        <div className="buttons"><ActionButton kind="host.clear" args={{ host: stopped.host }} label={`Clear ${stopped.host}`} primary title={`Removes the stop mark, so jobs use ${stopped.host} again. It does not fix the cause.`} /></div>
      </div>
    </section>
  );
}

/** Flow's word for why a host stopped, as the Needs you row says it. */
function stopCause(cause: string): string {
  if (cause === 'spend-limit') return 'Stopped on a spend limit';
  if (cause === 'auth') return 'Stopped on an auth error';
  return cause === '' ? 'Stopped' : `Stopped: ${cause}`;
}

function Jobs({ snapshot }: { snapshot: Snapshot }) {
  const [editing, setEditing] = useState<string | null>(null);
  const edited = snapshot.jobs.find((job) => job.name === editing) ?? null;
  const close = useCallback(() => setEditing(null), []);
  const scheduled = snapshot.jobs.filter((job) => job.schedule !== '' || job.installed);
  const unscheduled = snapshot.jobs.filter((job) => job.schedule === '' && !job.installed);
  const running = scheduled.filter((job) => job.state === 'running').length;
  return (
    <Fold className="jobs" title="Jobs" aside={<span className="muted">{scheduled.length} schedules{running > 0 ? ` · ${running} running` : ''}</span>} footer={<SourceFreshness name="jobs" freshness={snapshot.sources.jobs} />}>
      {scheduled.length === 0 ? <Empty>No jobs scheduled. Add one from the Schedule panel.</Empty> : (
        <ul className="job-list">
          {scheduled.map((job) => <JobRow key={job.name} job={job} root={snapshot.project.root} edit={(chosen) => setEditing(chosen.name)} />)}
        </ul>
      )}
      {unscheduled.length > 0 && <p className="muted job-unscheduled">Not scheduled: {unscheduled.map((job) => job.name).join(' · ')}. Add one under jobs.schedule in the flow settings.</p>}
      {edited !== null && <EditDialog job={edited} jobsHost={snapshot.project.jobsHost} close={close} />}
    </Fold>
  );
}

export const OVERDUE_HELP = 'Its interval has passed since the last run, so launchd starts it at its next chance, often when the Mac wakes.';

const STATE_HELP: Record<Job['state'], string> = {
  running: 'A run is going now.',
  scheduled: 'Installed with launchd. It runs on its schedule while you are logged in and the Mac is awake.',
  overdue: OVERDUE_HELP,
  paused: 'Its runs exit at once until you resume it. The schedule stays installed.',
  'not-loaded': 'Installed, but launchd has not loaded it, so it never runs. Install it again.',
  'not-installed': 'The config has this schedule, but launchd does not, so it never runs on its own.',
};

const STATE_WORD: Record<Job['state'], string> = {
  running: 'running', scheduled: 'scheduled', overdue: 'overdue', paused: 'paused', 'not-loaded': 'not loaded', 'not-installed': 'not installed',
};

/**
 * One schedule in one card: its state and when, the last run, and every button it takes. Its
 * runs and workers open under it in a box of their own that scrolls.
 */
function JobRow({ job, root, edit }: { job: Job; root: string; edit: (job: Job) => void }) {
  const args = { job: job.name };
  const tone = jobTone(job);
  const running = job.state === 'running' || job.running.length > 0;
  return (
    <li className="job-row" aria-label={`Job ${job.name}`}>
      <div className="job-top">
        <Dot tone={tone} />
        <div className="job-main">
          <div className="job-line">
            <span className="strong">{job.name}</span>
            <span className="muted">{[job.schedule, job.host].filter((part) => part !== null && part !== '').join(' · ')}</span>
            {job.args !== '' && <code className="job-args">{job.args}</code>}
          </div>
          <div className="job-line muted job-last-line">{job.last === null ? 'never ran' : `last ${clockTime(job.last.at)} · ${job.last.seconds}s · ${job.last.reason ?? job.last.result}`} · {job.runsThisWeek} runs this week{job.failedThisWeek > 0 ? `, ${job.failedThisWeek} failed` : ''}</div>
        </div>
        <span className={`job-state tone-${tone}`} title={job.configured ? STATE_HELP[job.state] : ORPHAN_HELP}>
          {!job.configured ? 'not in config' : job.state === 'scheduled' ? `next ${job.next === 'due' ? 'now' : job.next}` : STATE_WORD[job.state]}
        </span>
      </div>
      <div className="buttons job-buttons">
        {job.configured && (running
          ? <ActionButton kind="job.stop" args={args} label="Stop" primary={false} />
          : <ActionButton kind="job.run" args={args} label="Run now" primary title="Runs it once now, as the schedule would." />)}
        {job.configured && <button type="button" className="button" onClick={() => edit(job)}>Edit…</button>}
        {job.configured && (job.paused
          ? <ActionButton kind="job.resume" args={args} label="Resume" primary={false} />
          : <ActionButton kind="job.pause" args={args} label="Pause" primary={false} />)}
        <ActionButton kind="job.unschedule" args={args} label="Unschedule" primary={false} title="Removes it from launchd and from the config." />
        <TerminalButton path={root} job={job.name} />
      </div>
      <details className="job-more">
        <summary>History{job.workers.length > 0 ? ' and workers' : ''} <span className="muted">({job.recent.length} runs)</span></summary>
        <div className="job-history-box">
          <JobHistory job={job} />
        </div>
      </details>
    </li>
  );
}

const ORPHAN_HELP = 'Installed, but the config no longer names it. Unschedule it to remove it.';

/** Its runs, newest first, with why each skipped run skipped; for next, each worker as well. */
function JobHistory({ job }: { job: Job }) {
  return (
    <>
      {job.workers.length > 0 && (
        <ul className="row-list compact workers" aria-label={`Workers of ${job.name}`}>
          {job.workers.map((worker) => <WorkerRow key={worker.name} worker={worker} />)}
        </ul>
      )}
      {job.recent.length === 0 ? <p className="muted job-facts">No runs yet.</p> : (
        <ol className="row-list compact runs" aria-label={`Runs of ${job.name}`}>
          {job.recent.map((run, index) => (
            <li key={`${run.at}-${index}`}>
              <Dot tone={runTone(run)} />
              <span className="mono">{clockTime(run.at)}</span>
              <span className="mono muted">{run.worker ?? job.name}</span>
              <span className="strong">{run.outcome}</span>
              <span className="mono muted">{run.seconds}s</span>
              <span className="run-said">{run.reason ?? run.result}</span>
            </li>
          ))}
        </ol>
      )}
    </>
  );
}

function WorkerRow({ worker }: { worker: JobWorker }) {
  return (
    <li>
      <Dot tone={worker.running !== null ? 'running' : worker.last === null ? 'quiet' : runTone(worker.last)} />
      <span className="mono">{worker.name}</span>
      <span>{worker.host}</span>
      <span className="run-said">
        {worker.running !== null ? <>running <Since at={worker.running.since} /></> : worker.last === null ? 'never ran' : `${clockTime(worker.last.at)} · ${worker.last.reason ?? worker.last.result}`}
      </span>
    </li>
  );
}

function runTone(run: JobRun): Tone {
  if (run.exit !== null && run.exit !== 0) return 'failing';
  return 'quiet';
}

/**
 * The side panel: a new schedule of any job, or one run of it now, with the same settings on both
 * tabs. Every job takes a host, a model and an effort; next also an item and limits. It stays
 * open: a sent schedule or run says so and leaves the settings for the next one. An existing
 * schedule is changed from its row (Edit…), never here.
 */
function StartPanel({ jobs, jobsHost }: { jobs: Job[]; jobsHost: string }) {
  const actions = useActionsView();
  const [job, setJob] = useState('next');
  const ownWhen = (name: string): ScheduleWhen => whenFrom(jobs.find((each) => each.name === name)?.schedule ?? '');
  const [mode, setMode] = useState<'once' | 'schedule'>('schedule');
  const [when, setWhen] = useState(() => ownWhen('next'));
  const [label, setLabel] = useState('');
  const [said, setSaid] = useState<{ ok: boolean; text: string } | null>(null);
  const [sending, setSending] = useState(false);
  const run = useRunForm(startFormFrom('', jobsHost), () => setSaid(null));
  const isNext = job === 'next';
  const taken = jobs.filter((each) => each.job === job && (each.schedule !== '' || each.installed)).map((each) => each.name);
  const name = scheduleName(job, label);
  const pick = (to: string): void => {
    setJob(to); setWhen(ownWhen(to)); setLabel('');
    if (to !== 'next') run.change({ ...run.form, item: '', workers: '', maxSteps: '' });
    setSaid(null);
  };
  const submit = async (): Promise<void> => {
    const problem = startProblem(run.form) ?? (mode === 'schedule' ? scheduleProblem(label, when) ?? newScheduleProblem(job, label, taken) : null);
    if (problem !== null) { setSaid({ ok: false, text: problem }); return; }
    setSending(true);
    const outcome = mode === 'once'
      ? await actions.run('job.start', { job, ...startArgs(run.form) })
      : await actions.run('job.schedule', { job: name, schedule: isNext ? scheduleSpec(when, run.form) : pairSpec(when, run.form, '') });
    setSending(false);
    if (outcome.kind === 'refused') { setSaid({ ok: false, text: outcome.message }); return; }
    const where = isNext ? 'It shows under Runs once it claims an item.' : `It shows in ${job}'s history when it ends.`;
    setSaid({ ok: true, text: mode === 'once' ? `Started ${job} on ${run.form.host}. ${where}` : `Added ${name}. It shows under Jobs once it is installed.` });
    if (mode === 'schedule') setLabel('');
  };
  const tab = (to: 'once' | 'schedule', text: string) => (
    <button type="button" role="tab" aria-selected={mode === to} onClick={() => { setMode(to); setSaid(null); }}>{text}</button>
  );
  const own = !taken.includes(job);
  return (
    <section className="module start-panel" aria-label="New schedule or run">
      <header className="module-head">
        <div className="tabs" role="tablist" aria-label="Schedule or run once">{tab('schedule', 'Schedule')}{tab('once', 'Run once')}</div>
        <span className="muted">new {job}</span>
      </header>
      <form className="start-form" aria-label={mode === 'once' ? `Run ${job} once` : `Schedule ${job}`} onSubmit={(event) => { event.preventDefault(); void submit(); }}>
        <label className="field wide"><span>Job</span>
          <select value={job} onChange={(event) => pick(event.target.value)}>
            {Object.keys(JOB_KINDS).map((each) => <option key={each} value={each}>{each}</option>)}
          </select>
        </label>
        <p className="start-say">
          {`${job} ${JOB_KINDS[job] ?? ''}. `}
          {mode === 'once' ? 'Runs once now with these settings. The schedules stay as they are.' : `Adds a schedule of ${job} beside the others. The name tells it apart from them${own ? `; left empty, it is ${job} itself.` : '.'}`}
        </p>
        {mode === 'schedule' && (
          <>
            <label className="field wide"><span>Name</span>
              <span className="prefixed"><span className="mono muted">{job}-</span><input aria-label="Name" placeholder={own ? `empty makes ${job}` : 'such as codex'} value={label} onChange={(event) => { setLabel(event.target.value); setSaid(null); }} /></span>
            </label>
            <WhenFields when={when} setWhen={(value) => { setWhen(value); setSaid(null); }} />
          </>
        )}
        <RunFields run={run} pair={!isNext} />
        {said !== null && <p className={`chip start-said ${said.ok ? 'tone-running' : 'tone-failing'}`} role={said.ok ? 'status' : 'alert'}>{said.text}</p>}
        <div className="buttons">
          <button type="submit" className="button primary" disabled={sending}>{sending ? 'Sending…' : mode === 'once' ? 'Start' : `Add ${name}`}</button>
          <button type="button" className="button" onClick={() => { run.reset(); setLabel(''); setWhen(ownWhen(job)); setSaid(null); }}>Reset</button>
        </div>
      </form>
    </section>
  );
}

/**
 * Edit… on a job's row, in a dialog over the page: its timing, host, model and effort for every
 * job, and for next its item and limits too. Another job's own arguments stay as they are.
 * Saving rewrites that schedule in place, under the same name.
 */
function EditDialog({ job, jobsHost, close }: { job: Job; jobsHost: string; close: () => void }) {
  const actions = useActionsView();
  const isNext = job.job === 'next';
  const [when, setWhen] = useState(() => whenFrom(job.schedule));
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const loaded = startFormFrom(job.args, job.host ?? jobsHost);
  const run = useRunForm(isNext ? loaded : { ...loaded, item: '', workers: '', maxSteps: '' }, () => setError(null));
  const own = ownArgs(job.args).join(' ');
  const first = useRef<HTMLSelectElement>(null);
  useEffect(() => {
    first.current?.focus();
    const onKey = (event: KeyboardEvent): void => { if (event.key === 'Escape') close(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [close]);
  const submit = async (): Promise<void> => {
    const problem = scheduleProblem('', when) ?? startProblem(run.form);
    if (problem !== null) { setError(problem); return; }
    setSending(true);
    const schedule = isNext ? scheduleSpec(when, run.form) : pairSpec(when, run.form, job.args);
    const outcome = await actions.run('job.schedule', { job: job.name, schedule });
    setSending(false);
    if (outcome.kind === 'refused') { setError(outcome.message); return; }
    close();
  };
  return (
    <div className="modal-layer" onClick={(event) => { if (event.target === event.currentTarget) close(); }}>
      <div className="modal" role="dialog" aria-modal="true" aria-label={`Edit ${job.name}`}>
        <header className="module-head"><h2>Edit {job.name}</h2><button type="button" className="button" onClick={close}>Close</button></header>
        <form className="start-form" aria-label={`Edit ${job.name}`} onSubmit={(event) => { event.preventDefault(); void submit(); }}>
          <p className="start-say">
            {isNext ? `Changes when ${job.name} runs and what it runs. A run going now finishes as it started.` : `Changes when ${job.name} runs, and the host, model and effort of its sessions. From config is jobs.<host>.model and effort.${own === '' ? '' : ` Its own options stay: ${own}.`}`}
          </p>
          <WhenFields when={when} setWhen={(value) => { setWhen(value); setError(null); }} first={first} />
          <RunFields run={run} pair={!isNext} />
          {error !== null && <p className="chip tone-failing start-said" role="alert">{error}</p>}
          <div className="buttons">
            <button type="submit" className="button primary" disabled={sending}>{sending ? 'Saving…' : `Save ${job.name}`}</button>
            <button type="button" className="button" onClick={close}>Cancel</button>
          </div>
        </form>
      </div>
    </div>
  );
}

function Events({ snapshot }: { snapshot: Snapshot }) {
  const events = snapshot.events.slice(0, EVENTS_SHOWN);
  const all = routeHash({ projectId: snapshot.project.id, screen: 'activity', detail: null });
  return (
    <Module className="events" title="Events" aside={<a className="muted" href={all}>Show all</a>} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
      {events.length === 0 ? <Empty>No events yet.</Empty> : (
        <ol className="event-feed">
          {events.map((event, index) => (
            <li key={`${event.at}:${index}`}>
              <span className="mono muted">{clockTime(event.at)}</span>
              <span className="event-kind">{event.kind}</span>
              {event.item !== null && <ItemLink id={event.item} pages={snapshot} />}
              <span className="event-text" title={event.message}>{event.message}</span>
            </li>
          ))}
        </ol>
      )}
    </Module>
  );
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
