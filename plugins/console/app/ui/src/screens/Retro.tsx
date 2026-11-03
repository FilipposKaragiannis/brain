import { useState } from 'react';
import type { Lesson, RetroRun, Snapshot } from '../../../daemon/src/snapshot.ts';
import { clockTime, Since } from '../clock.tsx';
import { JOB_HOSTS } from '../jobStart.ts';
import { ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { Markdown } from '../Markdown.tsx';
import { lastRetro, lessonCount, lessonGroups, lessonsSinceRetro } from '../retro.ts';
import type { KindGroup } from '../retro.ts';
import { ActionButton, Empty, Module, SourceFreshness } from '../ui.tsx';

/** The job "Run retro now" starts. */
const RETRO_JOB = 'retro';
/** The length of the `YYYY-MM-DD` day that opens an ISO time. */
const DAY_LENGTH = 10;

type LessonView = 'since' | 'all';

/**
 * What the flow learnt and what its retros made of it: a head line with the counts and Run retro
 * now, the lessons grouped by kind then rule (those since the last retro, or all), and each retro
 * with its report.
 */
export function Retro({ snapshot }: { snapshot: Snapshot }) {
  const since = lessonsSinceRetro(snapshot);
  const [view, setView] = useState<LessonView>('since');
  const shown = view === 'since' ? since : snapshot.lessons;
  const choice = (to: LessonView, text: string) => (
    <button type="button" role="tab" aria-selected={view === to} onClick={() => setView(to)}>{text}</button>
  );
  const toggle = <div className="tabs" role="tablist" aria-label="Which lessons">{choice('since', `Since the last retro (${since.length})`)}{choice('all', `All (${snapshot.lessons.length})`)}</div>;
  const freshness = <SourceFreshness name="files" freshness={snapshot.sources.files} />;
  return (
    <div className="screen">
      <div className="retro-head">
        <p className="pulls-summary" aria-label="Summary"><RetroSummary snapshot={snapshot} since={since.length} /></p>
        <RunRetro snapshot={snapshot} />
      </div>
      <Module className="lessons" title="Lessons" aside={toggle} footer={freshness}>
        {shown.length === 0 ? <Empty>{view === 'since' ? 'No lesson since the last retro.' : 'No lesson recorded yet.'}</Empty> : <LessonGroups groups={lessonGroups(shown)} pages={snapshot} />}
      </Module>
      <Module className="retros" title="Retros" aside={<span className="muted">{snapshot.retros.length} in all</span>} footer={freshness}>
        {snapshot.retros.length === 0 ? <Empty>No retro has run yet.</Empty> : (
          <ol className="retro-runs">{snapshot.retros.map((run, index) => <RetroCard key={`${run.date}:${run.at ?? ''}`} run={run} open={index === 0} />)}</ol>
        )}
      </Module>
    </div>
  );
}

function RetroSummary({ snapshot, since }: { snapshot: Snapshot; since: number }) {
  const last = lastRetro(snapshot.retros);
  return (
    <>
      <span>{lessonCount(snapshot.lessons.length)} in all · {since} since the last retro</span>
      <span>{last === null ? 'No retro has run yet' : <>Last retro {runWhen(last)}{last.at !== null && <> · <Since at={last.at} /></>}</>}</span>
    </>
  );
}

/** When a run ran: its day and clock time on this machine, or its day alone for a report with no log line. */
function runWhen(run: RetroRun): string {
  if (run.at === null) return run.date;
  const moment = new Date(run.at);
  const day = [moment.getFullYear(), moment.getMonth() + 1, moment.getDate()].map((part) => String(part).padStart(2, '0')).join('-');
  return `${day} ${clockTime(run.at)}`;
}

/**
 * Starts the retro job once now through `job.start`, on the host its schedule names, else the
 * project's jobs host; the model and effort are the config's.
 */
function RunRetro({ snapshot }: { snapshot: Snapshot }) {
  const scheduled = snapshot.jobs.find((job) => job.job === RETRO_JOB)?.host ?? snapshot.project.jobsHost;
  const [host, setHost] = useState<string>((JOB_HOSTS as readonly string[]).includes(scheduled) ? scheduled : JOB_HOSTS[0]);
  return (
    <span className="retro-run">
      <label className="field"><span>Host</span>
        <select value={host} onChange={(event) => setHost(event.target.value)}>
          {JOB_HOSTS.map((each) => <option key={each} value={each}>{each}</option>)}
        </select>
      </label>
      <ActionButton kind="job.start" args={{ job: RETRO_JOB, host }} label="Run retro now" primary title={`Runs the retro job once now on ${host}. It reads the lessons since the last retro, and ends at once when there are none.`} />
    </span>
  );
}

function LessonGroups({ groups, pages }: { groups: KindGroup[]; pages: ItemPages }) {
  return (
    <div className="lesson-groups">
      {groups.map((group) => (
        <section key={group.kind} className="lesson-kind" aria-label={`Kind ${group.kind}`}>
          <h3>{group.kind} <span className="muted">{lessonCount(group.count)}</span></h3>
          {group.rules.map((rule) => (
            <div key={rule.rule ?? ''} className="lesson-rule" aria-label={`Rule ${rule.rule ?? 'none'}`}>
              <h4><span className="mono">{rule.rule ?? 'no rule'}</span> <span className="muted">{rule.lessons.length}</span></h4>
              <ul className="lesson-list">{rule.lessons.map((lesson) => <LessonRow key={lesson.line} lesson={lesson} pages={pages} />)}</ul>
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}

function LessonRow({ lesson, pages }: { lesson: Lesson; pages: ItemPages }) {
  const details = [lesson.step, lesson.host, lesson.at?.slice(0, DAY_LENGTH) ?? null].filter((part) => part !== null);
  return (
    <li className="lesson">
      <span className="lesson-text">{lesson.text}</span>
      <span className="lesson-where muted">
        {lesson.item !== null && <ItemLink id={lesson.item} pages={pages} />}
        {details.map((part) => <span key={part}> · {part}</span>)}
      </span>
    </li>
  );
}

function RetroCard({ run, open }: { run: RetroRun; open: boolean }) {
  const read = run.lessonsRead === null ? 'no log line' : `read ${lessonCount(run.lessonsRead)}`;
  const columns = [run.findings === '' ? null : `findings ${run.findings}`, run.applied === '' ? null : `applied ${run.applied}`].filter((part) => part !== null);
  return (
    <li className="retro-run-card" aria-label={`Retro ${run.date}`}>
      <details className="gate-doc" open={open}>
        <summary><span className="mono">{runWhen(run)}</span> · {read}{columns.map((part) => ` · ${part}`).join('')}</summary>
        {run.report === null ? <Empty>This run wrote no report.</Empty> : <Markdown text={run.report.text} />}
      </details>
    </li>
  );
}
