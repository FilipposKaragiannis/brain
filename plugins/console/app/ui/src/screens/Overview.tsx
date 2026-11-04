import type { Agent, Job, PullRequest, Run, Snapshot, SourceName, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, clockTime, formatDuration } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { readinessSentence } from '../readiness.ts';
import { lessonsSentence } from '../retro.ts';
import type { Route } from '../route.ts';
import { routeHash } from '../route.ts';
import { countTone, eventTone, jobTone, worktreeTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { PluginsFooter } from '../PluginsFooter.tsx';
import { SourcesRefresh } from '../SourcesRefresh.tsx';
import { useTranscript } from '../Transcript.tsx';
import { Dot, Empty, Module, SourceFreshness } from '../ui.tsx';
import { Disagreements } from './Disagreements.tsx';
import { NeedsYou } from './NeedsYou.tsx';

const EVENTS_SHOWN = 12;
const SOURCE_NAMES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board', 'pulls'];
/** How many names a tile's sub line lists before it says how many more. */
const NAMES_LISTED = 3;

/** A tile links to the screen that explains its count. */
type Tile = { label: string; count: number; tone: Tone; sub: string; screen: Route['screen'] };

export function Overview({ snapshot, go }: { snapshot: Snapshot; go: (route: Route) => void }) {
  const projectId = snapshot.project.id;
  const counts = snapshot.counts;
  return (
    <div className="screen">
      <section className="tiles" aria-label="Status">
        {tiles(snapshot).map((tile) => (
          <a key={tile.label} className={`tile tone-${tile.tone}`} href={routeHash({ projectId, screen: tile.screen, detail: null })}>
            <span className="tile-label">{tile.label}<Dot tone={tile.tone} /></span>
            <span className="tile-count">{tile.count}</span>
            <span className="tile-sub" title={tile.sub}>{tile.sub}</span>
          </a>
        ))}
      </section>
      <p className="readiness" aria-label="Readiness">{readinessSentence(snapshot.readiness, counts, snapshot.worktrees)}</p>
      <p className="readiness lessons-line" aria-label="Lessons">{lessonsSentence(snapshot)} <a className="module-link" href={routeHash({ projectId, screen: 'retro', detail: null })}>Retro</a></p>
      <div className="columns">
        <NeedsYou snapshot={snapshot} go={go} />
        <aside className="overview-side" aria-label="Live">
          <RunningNow snapshot={snapshot} />
          <Events snapshot={snapshot} />
        </aside>
      </div>
      {snapshot.disagreements.length > 0 && <Disagreements snapshot={snapshot} />}
      <Pool snapshot={snapshot} />
      <Module className="sources" title="Sources" aside={<SourcesRefresh projectId={projectId} />} footer={<span>taken at {clockTime(snapshot.takenAt)} · <Age seconds={0} takenAt={snapshot.takenAt} /> ago</span>}>
        <ul className="source-strip">
          {SOURCE_NAMES.map((name) => <li key={name}><SourceFreshness name={name} freshness={snapshot.sources[name]} /></li>)}
        </ul>
      </Module>
      <PluginsFooter project={snapshot.project} />
    </div>
  );
}

/** The five counts, each with a line that names what it counts. */
export function tiles(snapshot: Snapshot): Tile[] {
  const counts = snapshot.counts;
  const oldest = [...snapshot.attention].sort((left, right) => (right.ageSeconds ?? -1) - (left.ageSeconds ?? -1))[0];
  const runs = snapshot.runs.filter((run) => run.liveness !== 'dead');
  const stale = snapshot.worktrees.filter((worktree) => worktree.state === 'stale');
  const free = snapshot.worktrees.filter((worktree) => worktree.role === 'pool' && worktree.state === 'free');
  const failing = snapshot.pulls.filter((pull) => pull.state === 'checks-failing');
  return [
    { label: 'Needs you', count: counts.needsYou, tone: countTone(counts.needsYou, 'needs-you'), screen: 'gates',
      sub: oldest === undefined ? 'nothing waits on you' : `oldest ${formatDuration(oldest.ageSeconds)} · ${oldest.id}` },
    { label: 'Running', count: counts.running, tone: countTone(counts.running, 'running'), screen: 'agents',
      sub: runs.length === 0 ? `${counts.agents} agents, no run` : names(runs.map((run) => `${run.step} on ${run.item}`)) },
    { label: 'Stale', count: counts.stale, tone: countTone(counts.stale, 'stale'), screen: 'worktrees',
      sub: stale.length === 0 ? 'none behind or idle' : names(stale.map((worktree) => worktree.name)) },
    { label: 'Checks red', count: counts.pullsFailing, tone: countTone(counts.pullsFailing, 'failing'), screen: 'pulls',
      sub: failing.length === 0 ? 'every PR green or pending' : names(failing.map((pull) => `PR #${pull.number}`)) },
    { label: 'Free', count: counts.free, tone: 'quiet', screen: 'worktrees',
      sub: free.length === 0 ? 'the pool is full' : `${names(free.map((worktree) => worktree.name))} at ${snapshot.project.base}` },
  ];
}

function names(list: string[]): string {
  const shown = list.slice(0, NAMES_LISTED).join(', ');
  return list.length > NAMES_LISTED ? `${shown} and ${list.length - NAMES_LISTED} more` : shown;
}

/** The flow's own runs as they go, with the last line of a claude run, then the jobs due next. */
function RunningNow({ snapshot }: { snapshot: Snapshot }) {
  const agents = snapshot.agents.filter((agent) => agent.kind === 'agent');
  const agentsHref = routeHash({ projectId: snapshot.project.id, screen: 'agents', detail: null });
  const jobsHref = routeHash({ projectId: snapshot.project.id, screen: 'jobs', detail: null });
  const jobs = [...snapshot.jobs].filter((job) => job.configured && job.installed).sort(byNextRun);
  return (
    <Module className="running-now" title="Running now" aside={<span className="module-links"><a className="module-link" href={agentsHref}>Agents</a><a className="module-link" href={jobsHref}>Jobs</a></span>} footer={null}>
      {agents.length === 0 ? <Empty>No run is going.</Empty> : (
        <ul className="running-list">
          {agents.map((agent, index) => <RunningAgent key={agent.pid} agent={agent} snapshot={snapshot} lastLine={index === 0} />)}
        </ul>
      )}
      {jobs.length > 0 && (
        <ul className="due-list" aria-label="Scheduled jobs">
          {jobs.map((job) => <li key={job.name} className={`tone-${jobTone(job)}`}><JobMark job={job} /><span className="due-name">{job.name}{job.workers.length > 1 ? ` ×${job.workers.length}` : ''}</span><span className="due-when">{jobWhen(job)}</span></li>)}
        </ul>
      )}
    </Module>
  );
}

function RunningAgent({ agent, snapshot, lastLine }: { agent: Agent; snapshot: Snapshot; lastLine: boolean }) {
  const run = runOf(agent, snapshot.runs);
  const pull = pullOf(agent.item, snapshot.pulls);
  const where = [agent.worktree, agent.host, pull === null ? null : `PR #${pull.number}`].filter((part) => part !== null).join(' · ');
  return (
    <li className="running-agent">
      <div className="running-head">
        <Dot tone="running" />
        <div className="running-what">
          <div className="strong">{run?.step ?? 'agent'}{agent.item !== null && <> · <ItemLink id={agent.item} pages={snapshot} /></>}</div>
          <div className="muted">{where}</div>
        </div>
        <span className="running-age mono"><Age seconds={agent.elapsedSeconds} takenAt={snapshot.takenAt} /></span>
      </div>
      {lastLine && agent.session?.host === 'claude' && <LastLine agent={agent} snapshot={snapshot} />}
      <div className="run-stripes" aria-hidden="true" />
    </li>
  );
}

/** The newest line of a claude run's transcript, read again with every snapshot. */
function LastLine({ agent, snapshot }: { agent: Agent; snapshot: Snapshot }) {
  const read = useTranscript(snapshot.project.id, agent.pid, snapshot.takenAt, 1);
  if (read.kind !== 'read' || read.lines.length === 0) return null;
  const line = read.lines[read.lines.length - 1]!;
  return <div className="last-line mono" title={line.text}>{line.text}<span className="stream-cursor" aria-hidden="true">▌</span></div>;
}

function JobMark({ job }: { job: Job }) {
  if (job.state === 'running' || job.state === 'overdue' || job.next === 'due') return <span className="due-spin" aria-hidden="true" />;
  return <span className="due-ring" aria-hidden="true" />;
}

function jobWhen(job: Job): string {
  if (job.state === 'running') return 'running';
  if (job.state === 'paused') return 'paused';
  if (job.state === 'not-installed') return 'not installed';
  if (job.state === 'not-loaded') return 'not loaded';
  return job.next === 'due' || job.state === 'overdue' ? 'due now' : `at ${job.next}`;
}

/** Running first, then the ones due, then the rest in the order jobs.sh lists them. */
function byNextRun(left: Job, right: Job): number {
  return rank(left) - rank(right);
}

function rank(job: Job): number {
  if (job.state === 'running') return 0;
  if (job.state === 'overdue' || job.next === 'due') return 1;
  if (job.state === 'scheduled') return 2;
  return 3;
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

function Pool({ snapshot }: { snapshot: Snapshot }) {
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  const max = snapshot.project.poolMax;
  const href = routeHash({ projectId: snapshot.project.id, screen: 'worktrees', detail: null });
  const legend = (
    <span className="pool-legend">
      {(['running', 'needs-you', 'stale', 'quiet'] as const).map((tone) => <span key={tone}><Dot tone={tone} />{tone === 'quiet' ? 'free' : tone.replace('-', ' ')}</span>)}
    </span>
  );
  return (
    <Module className="pool" title={<>Pool <span className="muted">{pool.length} {pool.length === 1 ? 'worktree' : 'worktrees'}{max !== null && max > pool.length ? `, grows to ${max}` : ''} · base {snapshot.project.base}</span></>} aside={legend} footer={<SourceFreshness name="git" freshness={snapshot.sources.git} />}>
      {pool.length === 0 ? <Empty>No pool worktrees.</Empty> : (
        <div className="pool-map">{pool.map((worktree) => <PoolCell key={worktree.name} worktree={worktree} pages={snapshot} takenAt={snapshot.takenAt} href={href} />)}</div>
      )}
    </Module>
  );
}

function PoolCell({ worktree, pages, takenAt, href }: { worktree: Worktree; pages: ItemPages; takenAt: string; href: string }) {
  const tone = worktreeTone(worktree.state);
  return (
    <div className={`pool-cell tone-${tone}`} title={worktree.itemTitle === null ? `${worktree.name}: ${worktree.state}` : `${worktree.name}: ${worktree.itemTitle}`}>
      <a className="pool-name" href={href}><span className="mono">{worktree.name}</span><Dot tone={tone} /></a>
      {worktree.item === null
        ? <span className="pool-item">{worktree.state}</span>
        : <span className="pool-item"><ItemLink id={worktree.item} pages={pages} />{worktree.itemTitle !== null && <span className="pool-title">{worktree.itemTitle}</span>}</span>}
      <span className="pool-note">{poolNote(worktree)}{worktree.claimAgeSeconds !== null && worktree.state !== 'free' && <> · <Age seconds={worktree.claimAgeSeconds} takenAt={takenAt} /></>}</span>
      {worktree.state === 'running' && <div className="pool-stripes run-stripes" aria-hidden="true" />}
    </div>
  );
}

function poolNote(worktree: Worktree): string {
  if (worktree.state === 'free') return worktree.branch === null ? 'at the base' : `at ${worktree.branch}`;
  if (worktree.state === 'stale' && worktree.behindBase !== null && worktree.behindBase > 0) return `${worktree.behindBase} behind`;
  return worktree.gate ?? worktree.state;
}

/** The latest events, newest first: when, a dot for how it went, and what happened. */
function Events({ snapshot }: { snapshot: Snapshot }) {
  const events = snapshot.events.slice(0, EVENTS_SHOWN);
  const all = routeHash({ projectId: snapshot.project.id, screen: 'activity', detail: null });
  return (
    <Module className="events" title="Activity" aside={<a className="module-link" href={all}>Show all</a>} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
      {events.length === 0 ? <Empty>No events yet.</Empty> : (
        <ol className="event-feed-short">
          {events.map((event, index) => (
            <li key={`${event.at}:${index}`} className={index === 0 ? 'event-new' : undefined}>
              <span className="mono muted">{clockTime(event.at)}</span>
              <Dot tone={eventTone(event)} />
              <span className="event-line" title={event.message}>
                {event.item !== null && <><ItemLink id={event.item} pages={snapshot} /> </>}<span className="event-kind">{event.kind}</span> {event.message}
              </span>
            </li>
          ))}
        </ol>
      )}
    </Module>
  );
}
