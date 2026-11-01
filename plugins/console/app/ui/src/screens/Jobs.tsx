import { useCallback, useEffect, useRef, useState } from 'react';
import type { Job, JobRun, JobWorker, Snapshot, StoppedHost } from '../../../daemon/src/snapshot.ts';
import { clockTime, Since } from '../clock.tsx';
import { JOB_KINDS, newScheduleProblem, ownArgs, pairSpec, scheduleName, scheduleProblem, scheduleSpec, startArgs, startFormFrom, startProblem, whenFrom } from '../jobStart.ts';
import type { ScheduleWhen } from '../jobStart.ts';
import { ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { routeHash } from '../route.ts';
import { RunFields, useRunForm, WhenFields } from '../scheduleFields.tsx';
import { jobTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { ActionButton, Dot, Empty, Module, SourceFreshness, TerminalButton, useActionsView } from '../ui.tsx';

const EVENTS_SHOWN = 15;

/**
 * What is scheduled and what flow said. The main column lists the schedules; the side column holds
 * a stopped host first (no job runs on it), then the panel that adds a schedule or runs a job once,
 * then the latest events.
 */
export function Jobs({ snapshot }: { snapshot: Snapshot }) {
  return (
    <div className="screen jobs-screen">
      <div className="jobs-main">
        <Schedules snapshot={snapshot} />
      </div>
      <div className="jobs-side">
        {snapshot.stoppedHosts.map((stopped) => <StoppedHostCard key={stopped.host} stopped={stopped} pages={snapshot} />)}
        <StartPanel jobs={snapshot.jobs} jobsHost={snapshot.project.jobsHost} />
        <Events snapshot={snapshot} />
      </div>
    </div>
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

/** Every schedule as a card, then the jobs nobody scheduled in one line. */
function Schedules({ snapshot }: { snapshot: Snapshot }) {
  const [editing, setEditing] = useState<string | null>(null);
  const edited = snapshot.jobs.find((job) => job.name === editing) ?? null;
  const close = useCallback(() => setEditing(null), []);
  const scheduled = snapshot.jobs.filter((job) => job.schedule !== '' || job.installed);
  const unscheduled = snapshot.jobs.filter((job) => job.schedule === '' && !job.installed);
  const running = scheduled.filter((job) => job.state === 'running').length;
  return (
    <Module className="schedules" title="Schedules" aside={<span className="muted">{scheduled.length} schedules{running > 0 ? ` · ${running} running` : ''}</span>} footer={<SourceFreshness name="jobs" freshness={snapshot.sources.jobs} />}>
      {scheduled.length === 0 ? <Empty>No jobs scheduled. Add one from the Schedule panel.</Empty> : (
        <ul className="job-list">
          {scheduled.map((job) => <JobRow key={job.name} job={job} root={snapshot.project.root} edit={(chosen) => setEditing(chosen.name)} />)}
        </ul>
      )}
      {unscheduled.length > 0 && <p className="muted job-unscheduled">Not scheduled: {unscheduled.map((job) => job.name).join(' · ')}. Add one under jobs.schedule in the flow settings.</p>}
      {edited !== null && <EditDialog job={edited} jobsHost={snapshot.project.jobsHost} close={close} />}
    </Module>
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
    const where = isNext ? 'It shows on Agents once it claims an item.' : `It shows in ${job}'s history when it ends.`;
    setSaid({ ok: true, text: mode === 'once' ? `Started ${job} on ${run.form.host}. ${where}` : `Added ${name}. It shows under Schedules once it is installed.` });
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
